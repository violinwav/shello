import Foundation
import KeyFixtures
import ShelloCore
import ShelloModel
import ShelloSSH
import ShelloSecurity
import Testing

@testable import ShelloFeatures

/// The import sheet (README section 13): a pasted or picked key says what it is, asks for its
/// passphrase only when it is encrypted, and says clearly when the passphrase is missing or wrong,
/// or why a key is not imported. Once imported, the key's text and passphrase are gone from the
/// sheet, and a pasted key from the clipboard.
@Suite(.timeLimit(.minutes(1)))
struct ImportSSHKeyModelTests {
    let keys = TestKeys(secureEnclave: false)
    let clipboard = TestClipboard()

    @Test func encryptedKeyAsksForItsPassphraseUntilItIsRight() async throws {
        let model = ImportSSHKeyModel(store: keys.store, clipboard: clipboard)
        let variant = KeyFixture.Variant(key: .ecdsaP384, format: .openSSH, isEncrypted: true)

        model.paste(variant.text)

        let loaded = try #require(model.loaded)
        #expect(loaded.file.format == .openSSH && loaded.file.isEncrypted)
        #expect(loaded.source == .clipboard)
        #expect(model.needsPassphrase)
        #expect(model.canImport)
        #expect(model.name == "Imported Key")

        #expect(await model.importKey() == nil)
        #expect(model.passphraseProblem == "This key is encrypted. Enter its passphrase to import it.")
        model.passphrase = "not-the-passphrase"
        #expect(await model.importKey() == nil)
        #expect(model.passphraseProblem == "The passphrase isn’t right. Check it and try again.")
        #expect(model.loaded != nil)

        model.passphrase = KeyFixture.passphrase
        let key = try #require(await model.importKey())

        #expect(key.kind == .imported(.ecdsaP384))
        #expect(key.comment == "Imported Key")
        #expect(
            key.openSSHPublicKey
                == variant.key.publicKeyLine.replacing("shello-fixture-ecdsa-p384", with: "Imported Key"))
        #expect(try keys.store.keys() == [key])
        // The sheet lets go of the key's text and its passphrase, and the clipboard of its copy.
        #expect(model.loaded == nil)
        #expect(model.passphrase.isEmpty)
        #expect(model.passphraseProblem == nil)
        #expect(clipboard.clears == 1)
    }

    /// A key without a passphrase imports at once, with the name and signing policy chosen.
    @Test func keyWithoutAPassphraseImportsAsNamed() async throws {
        let model = ImportSSHKeyModel(store: keys.store, clipboard: clipboard)
        model.paste(KeyFixture.text("rsa-3072-pem"))
        #expect(!model.needsPassphrase)
        model.name = "  work laptop  "
        model.signingPolicy = .everyUse

        let key = try #require(await model.importKey())

        #expect(key.kind == .imported(.rsa))
        #expect(key.comment == "work laptop")
        #expect(key.signingPolicy == .everyUse)
        #expect(key.summary == "Imported RSA 3072 key in the Keychain, asks on every use")
    }

    /// The clipboard is emptied only once a pasted key is imported: not when importing fails, and not
    /// for a key that was removed.
    @Test func clipboardIsEmptiedOnlyOnceAPastedKeyIsImported() async throws {
        let model = ImportSSHKeyModel(store: keys.store, clipboard: clipboard)
        model.paste(KeyFixture.text("ed25519-openssh-encrypted"))
        #expect(await model.importKey() == nil)
        model.removeKey()
        #expect(clipboard.clears == 0)

        model.paste(KeyFixture.text("ed25519-openssh"))
        #expect(await model.importKey() != nil)

        #expect(clipboard.clears == 1)
    }

    /// A key Shello does not import, or a text that is no private key, is refused as it arrives,
    /// with the sentence that says why, and nothing to import.
    @Test(arguments: [
        ("dsa-openssh", SSHKeyImportError.dsaKey), ("rsa-1024-openssh", .rsaKeyTooSmall(bits: 1024)),
        ("ed25519.pub", .publicKey),
    ])
    func refusedKeyIsRefusedAsItArrives(_ name: String, _ error: SSHKeyImportError) async {
        let model = ImportSSHKeyModel(store: keys.store, clipboard: clipboard)

        model.paste(KeyFixture.text(name))

        #expect(model.loaded == nil)
        #expect(model.loadProblem == error.description)
        #expect(!model.canImport)
        #expect(await model.importKey() == nil)
    }

    /// A key that libssh refuses only once it has read it, as a PEM RSA key that is too small, stays
    /// out too, and says why.
    @Test func keyRefusedOnceReadSaysWhy() async throws {
        let model = ImportSSHKeyModel(store: keys.store, clipboard: clipboard)
        model.paste(KeyFixture.text("rsa-1024-pem"))
        #expect(model.loaded != nil)

        #expect(await model.importKey() == nil)

        #expect(model.loaded == nil)
        #expect(model.loadProblem == SSHKeyImportError.rsaKeyTooSmall(bits: 1024).description)
        #expect(try keys.store.keys().isEmpty)
    }

    /// A file from the Files app: its name, without its extension, becomes the key's, unless the
    /// user named the key already.
    @Test func pickedFileNamesTheKey() async throws {
        let directory = URL.temporaryDirectory.appending(path: "ImportSSHKeyModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "id_ecdsa.pem")
        try Data(KeyFixture.text("ecdsa-p256-pkcs8").utf8).write(to: file)
        let model = ImportSSHKeyModel(store: keys.store, clipboard: clipboard)

        model.load(fileAt: file)

        #expect(model.loaded?.source == .file("id_ecdsa"))
        #expect(model.loaded?.file.format == .pkcs8 && model.loaded?.file.isEncrypted == false)
        #expect(model.name == "id_ecdsa")

        model.name = "phone"
        model.load(fileAt: file)
        #expect(model.name == "phone")
        let key = try #require(await model.importKey())
        #expect(key.comment == "phone")
        #expect(clipboard.clears == 0)
    }

    @Test func fileTooLargeOrMissingIsRefused() throws {
        let directory = URL.temporaryDirectory.appending(path: "ImportSSHKeyModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let large = directory.appending(path: "large")
        try Data(count: ImportSSHKeyModel.maximumFileSize + 1).write(to: large)
        let model = ImportSSHKeyModel(store: keys.store, clipboard: clipboard)

        model.load(fileAt: large)
        #expect(model.loadProblem == "This file is too large to be a private key.")

        model.load(fileAt: directory.appending(path: "missing"))
        #expect(model.loadProblem == "Shello couldn’t read the file. Choose it again.")
        #expect(model.loaded == nil)

        model.fileChoiceFailed()
        #expect(model.loadProblem == "Shello couldn’t open the file. Choose it again.")
    }

    /// A private key pasted as the name would go at the end of the public key, which is shared: it is
    /// never a name, in either sheet.
    @Test(arguments: ["ed25519-openssh", "ecdsa-p256-pem", "rsa-3072-pkcs8-encrypted"])
    func privateKeyIsNeverTheName(_ fixture: String) async throws {
        let key = KeyFixture.text(fixture).filter { !$0.isNewline }
        let model = ImportSSHKeyModel(store: keys.store, clipboard: clipboard)
        model.paste(KeyFixture.text("ed25519-openssh"))
        model.name = key

        #expect(await model.importKey() == nil)
        #expect(model.visibleNameProblem == "That’s a private key. Enter a name instead.")
        let stored = try keys.store.keys()
        #expect(stored.isEmpty)

        let newKey = NewSSHKeyModel(store: keys.store, suggestedName: "Shello on iPhone")
        newKey.name = key
        #expect(newKey.nameProblem == "That’s a private key. Enter a name instead.")
        #expect(SSHKeyName.holdsPrivateKey("PuTTY-User-Key-File-3: ssh-ed25519"))
        #expect(!SSHKeyName.holdsPrivateKey("deploy@ci"))
    }

    /// The name must be there, and on one line; removing the key lets go of it and its passphrase.
    @Test func nameMustBeThereAndRemoveLetsTheKeyGo() async {
        let model = ImportSSHKeyModel(store: keys.store, clipboard: clipboard)
        model.paste(KeyFixture.text("ed25519-pkcs8-encrypted"))
        model.passphrase = KeyFixture.passphrase
        model.name = " "
        #expect(model.visibleNameProblem == nil)

        #expect(await model.importKey() == nil)
        #expect(model.visibleNameProblem == "Enter a name.")

        model.removeKey()
        #expect(model.loaded == nil)
        #expect(model.passphrase.isEmpty)
        #expect(!model.canImport)
    }

    /// Keys imported with the suggested name can still be told apart.
    @Test func suggestedNameIsOneNoKeyHasYet() async throws {
        _ = try await keys.make("Imported Key")

        #expect(ImportSSHKeyModel(store: keys.store, clipboard: clipboard).name == "Imported Key 2")
    }
}

/// Install on Host (README section 13): the hosts of the open connections, and what installing the
/// key did on each, in a sentence.
@Suite(.timeLimit(.minutes(1)))
struct InstallSSHKeyModelTests {
    let keys = TestKeys(secureEnclave: false)

    @Test func installsOnAHostAndSaysWhatHappened() async throws {
        let key = try await keys.make("phone")
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        let model = InstallSSHKeyModel(key: key) {
            [
                InstallSSHKeyModel.Target(host: nas) { installed in
                    #expect(installed == key)
                    return .added
                }
            ]
        }
        #expect(model.lastResult == nil)

        await model.install(on: try #require(model.hosts.first))

        #expect(model.outcomes[nas.id] == .installed(.added))
        #expect(model.lastResult == "Installed on nas: the key is in ~/.ssh/authorized_keys now.")
        #expect(!model.isInstalling)
    }

    @Test func saysWhenTheHostHasTheKeyOrWhyItFailed() async throws {
        let key = try await keys.make("phone")
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        let web = Host(name: "web", address: "web.lan", username: "deploy")
        let model = InstallSSHKeyModel(key: key) {
            [
                InstallSSHKeyModel.Target(host: nas) { _ in .alreadyInstalled },
                InstallSSHKeyModel.Target(host: web) { _ in
                    throw KeyInstallationError.commandFailed(exitStatus: 1, "mkdir: .ssh: Permission denied")
                },
            ]
        }

        await model.install(on: model.hosts[0])
        #expect(model.lastResult == "nas has the key already. Nothing changed.")
        await model.install(on: model.hosts[1])

        #expect(
            model.lastResult
                == "Couldn’t install on web. The server couldn’t add the key: mkdir: .ssh: Permission denied")
        #expect(model.outcomes[nas.id] == .installed(.alreadyInstalled))
    }

    /// Without tabs, there is no host to install on.
    @Test func withoutOpenConnectionsThereIsNoHost() async throws {
        let model = InstallSSHKeyModel(key: try await keys.make("phone"), tabs: nil)

        #expect(model.hosts.isEmpty)
    }
}

/// A clipboard that counts how often the sheet emptied it.
final class TestClipboard: KeyClipboard {
    private(set) var clears = 0

    func clear() {
        clears += 1
    }
}
