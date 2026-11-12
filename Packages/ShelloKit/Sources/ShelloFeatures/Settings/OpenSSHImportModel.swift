import Foundation
import Observation
import ShelloCore
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloStorage
import os

/// The import from an OpenSSH config file and a known_hosts file in Settings (README section 3):
/// reads the files the user picks in Files, and only those, shows what importing them would do, and
/// imports it once the user taps Import. Afterwards it keeps the summary, with every line it did not
/// import still listed.
@Observable
final class OpenSSHImportModel {
    /// One of the two files.
    enum FileKind: Hashable, Identifiable {
        case config
        case knownHosts

        var id: Self { self }

        /// The file as the screen names it.
        var title: String {
            switch self {
            case .config: "Config File"
            case .knownHosts: "known_hosts File"
            }
        }
    }

    /// A file the user picked, read.
    struct ChosenFile: Equatable {
        /// Its name, as Files shows it.
        let name: String
        let lineCount: Int
    }

    /// What the import did, for the summary.
    struct Summary: Equatable {
        let hosts: [OpenSSHImportPlan.NewHost]
        /// The host keys trusted.
        let keys: [OpenSSHImportPlan.NewKey]
        /// The keys of the file that differ from those Shello trusts, which it kept: the plan's
        /// conflicts, and any key trusted while the preview showed.
        let conflicts: [OpenSSHImportPlan.KnownKey]
        let notImported: [OpenSSHImportPlan.NotImported]
        /// The identity files to import as SSH keys, each with the hosts that name it.
        let keyFiles: [KeyFile]

        struct KeyFile: Equatable {
            let file: String
            let hosts: [String]
        }

        /// "Added 2 hosts and trusted 3 host keys."
        var status: String {
            let parts = [(hosts.count, "added", "host"), (keys.count, "trusted", "host key")]
                .filter { count, _, _ in count > 0 }
                .map { count, verb, noun in "\(verb) \(OpenSSHImportDisplay.count(count, noun))" }
            guard !parts.isEmpty else { return "Imported nothing." }
            let sentence = parts.joined(separator: " and ")
            return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
        }
    }

    let repository: HostImportRepository
    let sshKeys: SSHKeyStore?

    /// Whether the file importer shows, to choose `pickedKind`.
    var isPicking = false
    /// The file the file importer chooses, or chose last: the importer clears `isPicking` before it
    /// hands over the file.
    private(set) var pickedKind = FileKind.config
    /// A problem to show in an alert; the screen clears it when the user answers.
    var problem: String?

    private(set) var configFile: ChosenFile?
    private(set) var knownHostsFile: ChosenFile?
    /// What importing the chosen files would do, once one is chosen.
    private(set) var plan: OpenSSHImportPlan?
    /// What the import did, once it is done.
    private(set) var summary: Summary?
    /// What is under way and may take a while, such as reading a file that has to download first.
    private(set) var activity: String?
    /// Whether a file is being read, or the import planned. The sheet can still be closed meanwhile:
    /// what is read is then dropped with the model.
    private(set) var isReading = false
    /// Whether the import is being stored, in one short transaction, which the sheet waits for.
    private(set) var isImporting = false

    /// Whether a file is being read or the import stored.
    var isWorking: Bool { isReading || isImporting }

    private var config: OpenSSHConfig?
    private var knownHosts: KnownHosts?

    /// The longest file Shello reads: a known_hosts file of tens of thousands of lines.
    nonisolated static let maximumByteCount = 8 * 1024 * 1024

    init(repository: HostImportRepository, sshKeys: SSHKeyStore?) {
        self.repository = repository
        self.sshKeys = sshKeys
    }

    /// Whether Import can be tapped: a plan that adds something, and nothing under way.
    var canImport: Bool {
        guard let plan, summary == nil, !isWorking else { return false }
        return !plan.addsNothing
    }

    func file(_ kind: FileKind) -> ChosenFile? {
        switch kind {
        case .config: configFile
        case .knownHosts: knownHostsFile
        }
    }

    // MARK: - Files

    /// Opens the file importer to choose the file `kind`.
    func choose(_ kind: FileKind) {
        pickedKind = kind
        isPicking = true
    }

    /// Reads the file the user picked as `kind`, and plans the import again. Returns whether it read
    /// the file.
    @discardableResult
    func fileChosen(_ kind: FileKind, _ result: Result<URL, any Error>) async -> Bool {
        let url: URL
        switch result {
        case .success(let chosen):
            url = chosen
        case .failure(let error):
            Self.logger.error("The file importer failed: \(error)")
            problem = "Shello couldn’t open the file. \(error.localizedDescription)"
            return false
        }
        guard !isWorking else { return false }
        isReading = true
        activity = "Reading “\(url.lastPathComponent)”…"
        // Said only when reading takes a while, as when the file has to download from iCloud Drive.
        let slowRead = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            announce("Reading the file", priority: .low)
        }
        defer {
            slowRead.cancel()
            activity = nil
            isReading = false
        }
        do {
            let data = try await Self.read(url)
            let lineCount =
                data.isEmpty ? 0 : data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).count
            let chosen = ChosenFile(name: url.lastPathComponent, lineCount: lineCount)
            switch kind {
            case .config:
                config = await Self.parseConfig(data)
                configFile = chosen
            case .knownHosts:
                knownHosts = await Self.parseKnownHosts(data)
                knownHostsFile = chosen
            }
            await replan()
            return true
        } catch {
            Self.logger.error("Could not read a file to import: \(error)")
            problem = "Shello couldn’t read “\(url.lastPathComponent)”. \(error.localizedDescription)"
            return false
        }
    }

    /// Leaves the file `kind` out of the import.
    func remove(_ kind: FileKind) async {
        switch kind {
        case .config:
            config = nil
            configFile = nil
        case .knownHosts:
            knownHosts = nil
            knownHostsFile = nil
        }
        await replan()
    }

    /// Plans the import of the chosen files against what Shello has now.
    func replan() async {
        guard config != nil || knownHosts != nil else {
            plan = nil
            return
        }
        do {
            let saved = try await repository.savedHostsAndTrustedKeys()
            let keys = try sshKeys?.keys().map { ImportableSSHKey(id: $0.id, name: $0.comment) } ?? []
            plan = await Self.plan(config: config, knownHosts: knownHosts, saved: saved, sshKeys: keys)
        } catch {
            Self.logger.error("Could not plan the import: \(error)")
            plan = nil
            problem =
                "Shello couldn’t read your hosts and trusted host keys, so it can’t show what the import adds. Try "
                + "again, or restart Shello."
        }
    }

    // MARK: - Import

    /// Stores what the plan adds, in one transaction, and keeps the summary.
    func importPlan() async {
        guard let plan, canImport else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try await repository.importHosts(plan.hostsToStore, trusting: plan.keysToTrust)
            // A key trusted while the preview showed is kept, and joins the conflicts.
            let keptKeys = plan.keys.filter { result.keptOtherKey.contains($0.server) }
            let saved = try? await repository.savedHostsAndTrustedKeys()
            let newConflicts = keptKeys.compactMap { key -> OpenSSHImportPlan.KnownKey? in
                guard let trusted = saved?.trustedKeys[key.server]?.key else { return nil }
                return OpenSSHImportPlan.KnownKey(server: key.server, key: key.key, line: key.line, trusted: trusted)
            }
            let summary = Summary(
                hosts: plan.hosts, keys: plan.keys.filter { result.trusted.contains($0.server) },
                conflicts: plan.conflicts + newConflicts, notImported: plan.notImported,
                keyFiles: plan.keyFilesToImport.map { Summary.KeyFile(file: $0.file, hosts: $0.hosts) })
            self.summary = summary
            Self.logger.info("Imported \(summary.hosts.count) hosts and \(summary.keys.count) host keys from OpenSSH")
        } catch {
            Self.logger.error("Could not import from OpenSSH: \(error)")
            // The import is one transaction, so nothing of it is left behind.
            problem =
                "Shello couldn’t store the hosts and host keys, so nothing was imported. "
                + "\(error.localizedDescription) Try again."
        }
    }

    // MARK: - Away from the main actor

    /// Reads the file at `url`: it may come from a file provider such as iCloud Drive, which has to
    /// download it first.
    @concurrent
    private nonisolated static func read(_ url: URL) async throws -> Data {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maximumByteCount else { throw CocoaError(.fileReadTooLarge) }
                return try Data(contentsOf: url)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    @concurrent
    private nonisolated static func parseConfig(_ data: Data) async -> OpenSSHConfig {
        OpenSSHConfig(bytes: data)
    }

    @concurrent
    private nonisolated static func parseKnownHosts(_ data: Data) async -> KnownHosts {
        KnownHosts(bytes: data)
    }

    /// The plan, away from the main actor: hashed names take an HMAC for each server they could be.
    @concurrent
    private nonisolated static func plan(
        config: OpenSSHConfig?, knownHosts: KnownHosts?, saved: SavedHostsAndKeys, sshKeys: [ImportableSSHKey]
    ) async -> OpenSSHImportPlan {
        OpenSSHImport.plan(
            config: config, knownHosts: knownHosts, saved: saved.hosts, trustedKeys: saved.trustedKeys,
            sshKeys: sshKeys)
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "OpenSSHImport")
}
