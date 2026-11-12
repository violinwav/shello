import Foundation
import Observation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import UIKit

/// The import sheet (README section 13): a private key, pasted or picked in the Files app, its
/// passphrase if it is encrypted, a name and a signing policy. libssh reads the key
/// (`SSHKeyImport`), and the key store keeps it in the Keychain.
///
/// The key's text lives in a `Secret` from the moment it arrives, never in a text field: a field's
/// text, and its undo, would keep it. What the sheet shows of it is what it is, such as "OpenSSH
/// private key, encrypted". Once the key is imported, the text and the passphrase are gone from the
/// sheet, and the `Secret` overwrites its bytes. The passphrase is not kept.
///
/// Once a pasted key is imported, the clipboard is emptied: it would hold the private key, or the
/// passphrase if the user copied that in the meantime. An app cannot tell whether the clipboard
/// changed since the paste, because its own count of the clipboard's changes moves whenever one of
/// its text fields takes the keyboard, so the clipboard is emptied whatever it holds.
@Observable
final class ImportSSHKeyModel {
    /// A private key the sheet holds, not imported yet.
    struct LoadedKey {
        let text: Secret
        /// What the text says it is.
        let file: SSHKeyFile
        let source: Source
    }

    /// Where a private key came from.
    enum Source: Hashable {
        case clipboard
        /// A file of this name, without its extension.
        case file(String)
    }

    /// The largest file read: a private key in PEM is a few kilobytes at most.
    static let maximumFileSize = 64 * 1024

    let store: SSHKeyStore
    private(set) var loaded: LoadedKey?
    /// Why the text pasted or the file picked is not a key Shello imports, for the private key's
    /// section.
    private(set) var loadProblem: String?
    var passphrase = ""
    /// Why the passphrase did not read the key, for its section.
    private(set) var passphraseProblem: String?
    var name: String {
        didSet { nameIsSuggested = false }
    }
    var signingPolicy = SigningPolicy.standard
    /// Whether the Files app's picker shows.
    var isPickingFile = false
    /// Set when importing fails otherwise; the sheet shows it and clears it.
    var importError: String?
    private(set) var isImporting = false
    private var attemptedImport = false
    /// Whether the name is the one the sheet suggested, which a file's name then replaces.
    private var nameIsSuggested = true
    private let clipboard: any KeyClipboard

    /// An import into `store`, named "Imported Key", or "Imported Key 2" and so on when a key has
    /// that name, until a file's name or the user's replaces it. `clipboard` is the system's; tests
    /// pass their own.
    init(store: SSHKeyStore, clipboard: some KeyClipboard = SystemClipboard()) {
        self.store = store
        self.clipboard = clipboard
        let taken = Set((try? store.keys())?.map(\.comment) ?? [])
        name = NewSSHKeyModel.unused("Imported Key", taken: taken)
    }

    // MARK: - The key

    /// Takes the text pasted from the clipboard.
    func paste(_ text: String) {
        load(Secret(utf8: text), from: .clipboard)
    }

    /// Reads the file the Files app's picker picked, which may not exceed `maximumFileSize`.
    func load(fileAt url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumFileSize else {
                fail("This file is too large to be a private key.")
                return
            }
            var data = try Data(contentsOf: url, options: .uncached)
            // The secret takes a copy; this one is overwritten.
            defer { data.resetBytes(in: data.indices) }
            load(Secret(copying: data), from: .file(url.deletingPathExtension().lastPathComponent))
        } catch {
            SSHKeyListModel.logger.error("Could not read a private key's file: \(error)")
            fail("Shello couldn’t read the file. Choose it again.")
        }
    }

    /// Takes `text` as the key to import, if it is one Shello imports, as far as it tells before the
    /// passphrase.
    func load(_ text: Secret, from source: Source) {
        passphrase = ""
        passphraseProblem = nil
        do {
            loaded = LoadedKey(text: text, file: try SSHKeyImport.inspect(text), source: source)
            loadProblem = nil
            if case .file(let fileName) = source, nameIsSuggested, SSHKey.isValidComment(fileName) {
                name = fileName
                nameIsSuggested = true
            }
        } catch {
            fail(error.description)
        }
    }

    /// The Files app's picker could not hand over the file chosen.
    func fileChoiceFailed() {
        fail("Shello couldn’t open the file. Choose it again.")
    }

    /// Lets the key go, and its passphrase.
    func removeKey() {
        loaded = nil
        loadProblem = nil
        passphrase = ""
        passphraseProblem = nil
    }

    private func fail(_ problem: String) {
        loaded = nil
        loadProblem = problem
    }

    /// Whether the key is encrypted, and its passphrase is asked for.
    var needsPassphrase: Bool { loaded?.file.isEncrypted ?? false }

    // MARK: - The name

    /// What is wrong with the name, as a sentence that says how to fix it.
    var nameProblem: String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "Enter a name."
        }
        if SSHKeyName.holdsPrivateKey(name) {
            return SSHKeyName.privateKeyProblem
        }
        if !SSHKey.isValidComment(name) {
            return "Enter the name on one line."
        }
        return nil
    }

    /// The problem with the name, once the user has tried to import the key.
    var visibleNameProblem: String? {
        attemptedImport ? nameProblem : nil
    }

    // MARK: - Importing

    /// Whether Import can start: there is a key, and nothing is under way.
    var canImport: Bool { loaded != nil && !isImporting }

    /// Reads the key with its passphrase and keeps it, then lets go of its text and its passphrase,
    /// and returns it; nil if something is missing or wrong, which the sheet then says.
    func importKey() async -> SSHKey? {
        attemptedImport = true
        guard let loaded, nameProblem == nil, !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        passphraseProblem = nil
        let passphrase = needsPassphrase && !self.passphrase.isEmpty ? Secret(utf8: self.passphrase) : nil
        do {
            let material = try await Self.read(loaded.text, passphrase: passphrase)
            let key = try await store.importKey(material, comment: name, signingPolicy: signingPolicy)
            finish(loaded)
            return key
        } catch let error as SSHKeyImportError {
            switch error {
            case .passphraseRequired, .wrongPassphrase:
                passphraseProblem = error.description
            default:
                fail(error.description)
            }
        } catch {
            SSHKeyListModel.logger.error("Could not import an SSH key: \(error)")
            importError = String(describing: error)
        }
        return nil
    }

    /// libssh reads the key off the main actor: bcrypt makes an encrypted OpenSSH key's passphrase
    /// take a while on purpose.
    @concurrent
    nonisolated private static func read(
        _ text: Secret, passphrase: Secret?
    ) async throws(SSHKeyImportError) -> ImportedKeyMaterial {
        try SSHKeyImport.read(text, passphrase: passphrase)
    }

    /// Lets go of the key's text and its passphrase once it is imported, and empties the clipboard
    /// of a pasted key.
    private func finish(_ imported: LoadedKey) {
        loaded = nil
        passphrase = ""
        if imported.source == .clipboard {
            clipboard.clear()
        }
    }
}

/// The clipboard, as the import sheet uses it.
protocol KeyClipboard {
    /// Empties the clipboard.
    func clear()
}

/// The system's clipboard. Emptying it asks the user nothing.
struct SystemClipboard: KeyClipboard {
    func clear() {
        UIPasteboard.general.items = []
    }
}
