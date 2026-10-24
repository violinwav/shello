import Foundation
import ShelloModel
import Testing

@testable import ShelloSSH

/// Imported keys, read by libssh (README section 13), and host keys as Shello shows them.
struct KeyTests {
    @Test func readsAnOpenSSHKey() throws {
        _ = try ImportedKey(text: TestSecret(TestServer.clientKey), passphrase: nil)
    }

    @Test func readsAnEncryptedKeyWithItsPassphrase() throws {
        _ = try ImportedKey(
            text: TestSecret(TestServer.encryptedClientKey), passphrase: TestSecret(TestServer.passphrase))
    }

    @Test(arguments: [nil, "wrong passphrase"])
    func encryptedKeyWithoutItsPassphraseIsInvalid(_ passphrase: String?) {
        #expect(throws: SSHError.invalidKey) {
            _ = try ImportedKey(
                text: TestSecret(TestServer.encryptedClientKey), passphrase: passphrase.map(TestSecret.init))
        }
    }

    @Test(arguments: ["", "not a key", TestServer.hostKeyLine])
    func textThatIsNoPrivateKeyIsInvalid(_ text: String) {
        #expect(throws: SSHError.invalidKey) {
            _ = try ImportedKey(text: TestSecret(text), passphrase: nil)
        }
    }

    /// `ssh-keygen -l -E sha256` leaves out base64's padding. ConnectionTests checks the whole
    /// fingerprint of the test server's host key against it.
    @Test func fingerprintLeavesOutBase64Padding() {
        #expect(HostKey.fingerprint(sha256: Data([0xFF])) == "SHA256:/w")
        #expect(HostKey.fingerprint(sha256: Data(repeating: 0, count: 32)).count == 7 + 43)
    }
}

extension TestServer {
    /// Host key a's public key line, which is no private key.
    static let hostKeyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgTJMsflS9c2SZNLqrNUxilEPdrI1trFCrvwBsv0BQ9"
}
