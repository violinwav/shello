import Foundation
import Observation
import ShelloStorage
import os

/// Export and import in Settings (README section 15): makes the file for the file exporter, reads
/// the file the user picks in the file importer, and imports it once the user has confirmed what it
/// holds.
@Observable
final class ExportImportModel {
    /// What the screen asks or tells the user in an alert.
    enum Alert: Equatable {
        /// The file can be imported, once the user confirms.
        case confirmImport(PendingImport)
        /// The file holds no host, group or tag.
        case nothingToImport
        /// Something went wrong, as `message` says.
        case problem(title: String, message: String)

        var title: String {
            switch self {
            case .confirmImport(let pending): pending.title
            case .nothingToImport: "Nothing to Import"
            case .problem(let title, _): title
            }
        }

        var message: String {
            switch self {
            case .confirmImport(let pending): pending.message
            case .nothingToImport: "The file has no hosts, groups or tags."
            case .problem(_, let message): message
            }
        }
    }

    let repository: ExportRepository

    /// Whether the file exporter shows. `export()` sets it once the file is ready.
    var isExporting = false
    /// Whether the file importer shows.
    var isImporting = false
    /// The alert to show; the screen clears it when the user answers.
    var alert: Alert?

    /// The file for the file exporter to save.
    private(set) var exportDocument: ExportDocument?
    /// The name the file exporter suggests for `exportDocument`, fixed when the export is made: a
    /// name that changed while the exporter shows would reset it.
    private(set) var exportFilename = ""
    /// What the last export or import did.
    private(set) var status: String?
    /// What is under way and may take a while, such as reading a file that has to download first.
    private(set) var activity: String?
    /// Whether an export or an import is under way.
    private(set) var isWorking = false
    private var exportCounts: RecordCounts?
    private let now: () -> Date

    init(repository: ExportRepository, now: @escaping () -> Date = { .now }) {
        self.repository = repository
        self.now = now
    }

    /// The name the file exporter suggests, with the time down to the second, as in screenshot
    /// names: "Shello Export 2026-10-21 14.05.09". Exporting again later does not ask to replace the
    /// earlier file.
    static func exportFilename(at time: Date = .now) -> String {
        let style = Date.ISO8601FormatStyle(dateTimeSeparator: .space, timeZone: .current)
            .year().month().day().time(includingFractionalSeconds: false)
        return "Shello Export \(time.formatted(style).replacing(":", with: "."))"
    }

    // MARK: - Export

    /// Reads every host, group and tag into a file, and opens the file exporter to save it.
    func export() async {
        guard !isWorking else { return }
        isWorking = true
        status = nil
        defer { isWorking = false }
        do {
            let file = try await repository.export()
            exportDocument = ExportDocument(data: try file.encoded())
            exportFilename = Self.exportFilename(at: now())
            exportCounts = file.counts
            isExporting = true
        } catch {
            Self.logger.error("Could not export: \(error)")
            alert = .problem(
                title: "Couldn’t Export", message: "Shello couldn’t read your hosts, groups and tags.\n\n\(error)")
        }
    }

    /// The file exporter saved the file, or could not. The result names the file as it was saved: the
    /// user may have renamed it in the exporter.
    func exportFinished(_ result: Result<URL, any Error>) {
        exportDocument = nil
        switch result {
        case .success(let url):
            let counts = exportCounts ?? RecordCounts(hosts: 0, groups: 0, tags: 0)
            Self.logger.info("Exported \(counts.hosts) hosts, \(counts.groups) groups, \(counts.tags) tags")
            report("Exported \(counts.listed) to “\(url.lastPathComponent)”.")
        case .failure(let error):
            Self.logger.error("Could not save the export: \(error)")
            alert = .problem(title: "Couldn’t Save the Export", message: error.localizedDescription)
        }
    }

    /// The user closed the file exporter without saving.
    func exportCancelled() {
        exportDocument = nil
    }

    // MARK: - Import

    /// Reads the file the user picked, and asks to confirm what importing it would do. A file that
    /// cannot be imported is refused with the reason, before anything is stored.
    func fileChosen(_ result: Result<URL, any Error>) async {
        let url: URL
        switch result {
        case .success(let chosen):
            url = chosen
        case .failure(let error):
            Self.logger.error("The file importer failed: \(error)")
            alert = .problem(title: "Can’t Open the File", message: error.localizedDescription)
            return
        }
        guard !isWorking else { return }
        isWorking = true
        status = nil
        activity = "Reading the file…"
        // Said only when reading takes a while, as when the file has to download from iCloud Drive.
        let slowRead = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            announce("Reading the file", priority: .low)
        }
        defer {
            slowRead.cancel()
            activity = nil
            isWorking = false
        }
        do {
            let file = try await Self.readExport(at: url)
            guard !file.counts.isEmpty else {
                alert = .nothingToImport
                return
            }
            let summary = try await repository.importSummary(of: file)
            alert = .confirmImport(PendingImport(file: file, summary: summary))
        } catch let error as ImportError {
            Self.logger.error("Refused a file to import: \(error)")
            alert = .problem(title: "Can’t Import the File", message: error.description)
        } catch {
            Self.logger.error("Could not read a file to import: \(error)")
            alert = .problem(title: "Can’t Import the File", message: error.localizedDescription)
        }
    }

    /// Imports the file the user confirmed, in one transaction.
    func confirmImport(_ pending: PendingImport) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await repository.importFile(pending.file)
            let counts = pending.summary.records
            Self.logger.info("Imported \(counts.hosts) hosts, \(counts.groups) groups, \(counts.tags) tags")
            report("Imported \(counts.listed).")
        } catch {
            Self.logger.error("Could not import: \(error)")
            // The import is one transaction, so nothing of it is left behind.
            alert = .problem(
                title: "Couldn’t Import the File",
                message: "Shello couldn’t store the file’s hosts, groups and tags, so nothing was imported.\n\n\(error)"
            )
        }
    }

    /// Shows what happened, and says it to VoiceOver, which would not notice the footer change.
    private func report(_ status: String) {
        self.status = status
        announce(status)
    }

    /// Reads and checks the file at `url`, away from the main actor: the file may come from a file
    /// provider such as iCloud Drive, which has to download it first.
    @concurrent
    private nonisolated static func readExport(at url: URL) async throws -> ExportFile {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, any Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try readData(at: url) }
        }
        if let coordinationError { throw coordinationError }
        return try ExportFile(data: result.get())
    }

    /// The file's contents, unless it is larger than any export: then it is not read at all.
    private nonisolated static func readData(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= ExportFile.maximumByteCount else { throw ImportError.tooLarge }
        return try Data(contentsOf: url)
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "ExportImport")
}

/// A file the user picked, read and checked, and what importing it would do.
struct PendingImport: Equatable {
    let file: ExportFile
    let summary: ImportSummary

    /// "Import 12 hosts, 3 groups and 5 tags?"
    var title: String {
        "Import \(summary.records.listed)?"
    }

    /// The rule for records already in Shello, and how many of the file's records it applies to.
    var message: String {
        let replacing =
            summary.replacing.isEmpty
            ? "None of these are in Shello yet." : "This replaces \(summary.replacing.listed)."
        return "Hosts, groups and tags already in Shello are replaced by their version in the file. \(replacing) "
            + "Nothing else changes."
    }
}

extension RecordCounts {
    /// "12 hosts, 3 groups and 5 tags", leaving out the kinds there are none of.
    var listed: String {
        let parts = [(hosts, "host", "hosts"), (groups, "group", "groups"), (tags, "tag", "tags")]
            .filter { count, _, _ in count > 0 }
            .map { count, one, many in "\(count) \(count == 1 ? one : many)" }
        guard let last = parts.last else { return "no hosts, groups or tags" }
        return parts.count == 1 ? last : "\(parts.dropLast().joined(separator: ", ")) and \(last)"
    }
}
