import Foundation
import ShelloModel
import ShelloSecurity
import ShelloStorage
import Testing

@testable import ShelloFeatures

/// Secrets never reach the database or the export (README section 13, docs/spec/EXPORT.md). A host
/// saved with a password through the host editor leaves no trace of it in either, and one saved
/// with an SSH key holds the key's identifier only.
@Suite(.timeLimit(.minutes(1)))
struct SecretsStayOutTests {
    let test: TestDatabase
    let secrets = TestSecrets()
    /// A password that no field, identifier or page of the database holds by chance.
    let password = "Correct-Horse-Battery-7f3a9c"

    init() throws {
        test = try TestDatabase()
    }

    /// Every file SQLite writes, the write-ahead log included, where a new row lives at first.
    @Test func passwordIsInNoFileOfTheDatabase() async throws {
        let host = try await saveHostWithPassword()

        let files = try FileManager.default.contentsOfDirectory(at: test.root, includingPropertiesForKeys: nil)
            .map { try Data(contentsOf: $0) }

        #expect(files.count >= 2)
        // The search works: the host's name is there.
        #expect(files.contains { $0.range(of: Data(host.name.utf8)) != nil })
        #expect(files.allSatisfy { $0.range(of: Data(password.utf8)) == nil })
        #expect(try secrets.password(of: host.id) == password)
    }

    @Test func passwordIsNotInTheExport() async throws {
        let host = try await saveHostWithPassword()

        let data = try await test.exports.export().encoded()

        #expect(data.range(of: Data(password.utf8)) == nil)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(host.id.uuidString))
        #expect(json.contains(#""authMethod" : "password""#))
    }

    /// Neither the private key of an Ed25519 key nor the blob of a Secure Enclave key reaches the
    /// database or the export, and copying the key puts its public key alone on the clipboard.
    @Test(arguments: [SSHKey.Kind.secureEnclave, .ed25519])
    func privateKeyStaysInTheKeychain(kind: SSHKey.Kind) async throws {
        let keys = TestKeys()
        let key = try await keys.make("homelab", kind: kind)
        let keyData = try #require(keys.keyData(of: key))
        let model = HostEditorModel(repository: test.repository, keys: keys.store, host: nil)
        model.draft.name = "nas-01"
        model.draft.address = "nas.lan"
        model.chooseSSHKey(key.id)
        #expect(await model.save())

        let files = try FileManager.default.contentsOfDirectory(at: test.root, includingPropertiesForKeys: nil)
            .map { try Data(contentsOf: $0) }
        #expect(files.contains { $0.range(of: Data("nas-01".utf8)) != nil })
        #expect(files.allSatisfy { !Self.holds($0, keyData) })

        let export = try await test.exports.export().encoded()
        #expect(String(decoding: export, as: UTF8.self).contains(key.id.uuidString))
        #expect(!Self.holds(export, keyData))

        var clipboard: [String] = []
        SSHKeyDetailModel(store: keys.store, key: key) { clipboard.append($0) }.copyPublicKey()
        #expect(clipboard == [key.openSSHPublicKey])
        #expect(!Self.holds(Data(clipboard[0].utf8), keyData))
    }

    /// Whether `data` holds `secret`'s bytes as they are, or as base64 or hex text.
    private static func holds(_ data: Data, _ secret: Data) -> Bool {
        let hex = secret.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
        let text = String(decoding: data, as: UTF8.self)
        return data.range(of: secret) != nil || text.contains(secret.base64EncodedString())
            || text.localizedCaseInsensitiveContains(hex)
    }

    private func saveHostWithPassword() async throws -> Host {
        let model = HostEditorModel(repository: test.repository, secrets: secrets.store, host: nil)
        model.draft.name = "vault-01"
        model.draft.address = "vault.lan"
        model.draft.authMethod = .password
        model.password = password
        #expect(await model.save())
        return try #require(try await test.repository.hosts().first)
    }
}
