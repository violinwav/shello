import Foundation
import KeyFixtures
import ShelloModel
import ShelloSSH
import ShelloSecurity
import Testing

@testable import ShelloCore

/// Signing in with imported keys (README section 13), the whole way: libssh reads the fixture,
/// decrypting it with its passphrase, the key store keeps it, and the host signs in with it through
/// Shello's SSH agent, as with a generated key. Each type Shello imports signs in to OpenSSH 10, and
/// RSA, with SHA-512, to OpenSSH 8.8, which refuses SHA-1's `ssh-rsa`. The test servers let the test
/// user in with the fixtures (TestServers/keys/import_fixtures.pub); CI's sshd does too.
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(1)))
struct ImportedKeySignInTests {
    /// One format of each key, the encrypted ones read with their passphrase.
    static let variants = [
        KeyFixture.Variant(key: .ed25519, format: .openSSH, isEncrypted: true),
        KeyFixture.Variant(key: .ecdsaP256, format: .pem, isEncrypted: true),
        KeyFixture.Variant(key: .ecdsaP384, format: .pkcs8, isEncrypted: true),
        KeyFixture.Variant(key: .rsa3072, format: .pkcs8, isEncrypted: false),
    ]

    @Test(arguments: variants)
    func importedKeySignsInThroughTheAgent(_ variant: KeyFixture.Variant) async throws {
        let test = try TestConnector()
        let host = try await importedKeyHost(variant, of: test, port: TestServer.port)

        let connection = try await test.connector.connect(to: host) { _, _ in false }

        let whoami = try await connection.run("whoami")
        #expect(String(decoding: whoami.output, as: UTF8.self) == "\(TestServer.user)\n")
        await connection.close()
    }

    /// OpenSSH 8.8, the oldest Shello supports, takes RSA keys' SHA-2 signatures only.
    @Test(.enabled(TestServer.openSSH8NotRunning) { await TestServer.isOpenSSH8Running })
    func rsaKeySignsInToOpenSSH8WithSHA2() async throws {
        let test = try TestConnector()
        let variant = KeyFixture.Variant(key: .rsa3072, format: .pem, isEncrypted: true)
        let host = try await importedKeyHost(variant, of: test, port: TestServer.openSSH8Port)

        let connection = try await test.connector.connect(to: host) { _, _ in false }

        let whoami = try await connection.run("whoami")
        #expect(String(decoding: whoami.output, as: UTF8.self) == "shello\n")
        await connection.close()
    }

    /// The signing policy is an imported key's too: on every use, Face ID asks, naming the host.
    @Test func everyUseImportedKeyAsksNamingTheHost() async throws {
        let test = try TestConnector()
        let host = try await importedKeyHost(
            Self.variants[2], of: test, port: TestServer.port, signingPolicy: .everyUse)

        let connection = try await test.connector.connect(to: host) { _, _ in false }

        #expect(test.authentication.reasons == ["Sign in to test server with “imported”."])
        await connection.close()
    }

    /// A host on `port` that signs in with `variant`, imported into `test`'s key store, whose server's
    /// host key is trusted already.
    private func importedKeyHost(
        _ variant: KeyFixture.Variant, of test: TestConnector, port: UInt16,
        signingPolicy: SigningPolicy = .whileUnlocked
    ) async throws -> Host {
        let material = try SSHKeyImport.read(
            Secret(utf8: variant.text), passphrase: variant.isEncrypted ? Secret(utf8: KeyFixture.passphrase) : nil)
        let key = try await test.keys.importKey(material, comment: "imported", signingPolicy: signingPolicy)
        var host = try test.host(password: nil, port: port, user: port == TestServer.port ? TestServer.user : "shello")
        host.authMethod = .sshKey
        host.sshKeyID = key.id
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        return host
    }
}
