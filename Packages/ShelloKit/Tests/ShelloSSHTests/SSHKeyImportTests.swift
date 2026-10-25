import Foundation
import KeyFixtures
import ShelloModel
import Testing

@testable import ShelloSSH

/// Importing SSH keys (README section 13): libssh reads private keys in OpenSSH's format, PEM and
/// PKCS #8, plain or encrypted, of every type Shello imports, from the fixtures ssh-keygen made
/// (Tests/KeyFixtures). Each key reads as the same private key in every format, with the public key
/// of its `.pub` file. A key Shello does not import is refused with a sentence that says why, and a
/// passphrase that is missing or wrong says so.
struct SSHKeyImportTests {
    @Test(arguments: KeyFixture.variants)
    func readsEveryFormatOfEveryKey(_ variant: KeyFixture.Variant) throws {
        let file = try SSHKeyImport.inspect(TestSecret(variant.text))
        #expect(file.isEncrypted == variant.isEncrypted)
        #expect(file.format == Self.format(of: variant))

        let material = try SSHKeyImport.read(
            TestSecret(variant.text), passphrase: variant.isEncrypted ? TestSecret(KeyFixture.passphrase) : nil)

        #expect(material.algorithm == Self.algorithm(of: variant.key))
        #expect(material.publicKey == Self.publicKey(of: variant.key))
        let privateKey = Self.bytes(of: material.privateKey)
        switch material.algorithm {
        case .ed25519, .ecdsaP256: #expect(privateKey.count == 32)
        case .ecdsaP384: #expect(privateKey.count == 48)
        // PKCS #1's RSAPrivateKey: a SEQUENCE with a length of two bytes.
        case .rsa: #expect(privateKey.starts(with: [0x30, 0x82]))
        }
    }

    /// The formats of one key hold the same key: libssh's reading of each gives the same bytes.
    @Test(arguments: KeyFixture.Key.allCases)
    func everyFormatOfAKeyReadsAsTheSamePrivateKey(_ key: KeyFixture.Key) throws {
        let privateKeys = try key.variants.map { variant in
            let material = try SSHKeyImport.read(
                TestSecret(variant.text), passphrase: variant.isEncrypted ? TestSecret(KeyFixture.passphrase) : nil)
            return Self.bytes(of: material.privateKey)
        }

        #expect(Set(privateKeys).count == 1)
    }

    /// An encrypted key without its passphrase says it needs one, an empty passphrase counts as
    /// none, and a wrong one says it is wrong. libssh never asks on a terminal.
    @Test(arguments: KeyFixture.variants.filter(\.isEncrypted))
    func encryptedKeyNeedsItsPassphrase(_ variant: KeyFixture.Variant) {
        #expect(throws: SSHKeyImportError.passphraseRequired) {
            try SSHKeyImport.read(TestSecret(variant.text), passphrase: nil)
        }
        #expect(throws: SSHKeyImportError.passphraseRequired) {
            try SSHKeyImport.read(TestSecret(variant.text), passphrase: TestSecret(""))
        }
        #expect(throws: SSHKeyImportError.wrongPassphrase) {
            try SSHKeyImport.read(TestSecret(variant.text), passphrase: TestSecret("not-the-passphrase"))
        }
    }

    /// A passphrase given for a key that is not encrypted is left alone.
    @Test func keyWithoutAPassphraseIgnoresOne() throws {
        let material = try SSHKeyImport.read(
            TestSecret(KeyFixture.text("ed25519-openssh")), passphrase: TestSecret(KeyFixture.passphrase))
        #expect(material.algorithm == .ed25519)
    }

    /// What surrounds a key, as in a message the key was pasted from, and Windows' line breaks, are
    /// left alone, as by ssh-keygen.
    @Test(arguments: [
        KeyFixture.Variant(key: .ed25519, format: .openSSH, isEncrypted: true),
        KeyFixture.Variant(key: .rsa3072, format: .pem, isEncrypted: true),
        KeyFixture.Variant(key: .ecdsaP384, format: .pkcs8, isEncrypted: false),
    ])
    func keyAmongOtherTextReads(_ variant: KeyFixture.Variant) throws {
        let passphrase = variant.isEncrypted ? TestSecret(KeyFixture.passphrase) : nil
        let surrounded = "Here is the key:\n\n" + variant.text + "\nThanks!\n"
        let windows = variant.text.replacing("\n", with: "\r\n")

        for text in [surrounded, windows] {
            let material = try SSHKeyImport.read(TestSecret(text), passphrase: passphrase)
            #expect(material.publicKey == Self.publicKey(of: variant.key))
        }
    }

    /// The smallest RSA key Shello imports has 2048 bits.
    @Test func rsaKeyOf2048BitsReads() throws {
        let material = try SSHKeyImport.read(TestSecret(KeyFixture.text("rsa-2048-openssh")), passphrase: nil)

        #expect(material.algorithm == .rsa)
        #expect(PublicKeySummary(wireRepresentation: material.publicKey)?.rsaBits == 2048)
    }

    // MARK: - Refused

    /// DSA keys are refused, before any passphrase, in OpenSSH's format and in PEM: OpenSSH 10
    /// removed DSA, and libssh 0.12 has none.
    @Test(arguments: ["dsa-openssh", "dsa-pem"])
    func dsaKeyIsRefused(_ name: String) {
        #expect(throws: SSHKeyImportError.dsaKey) { try SSHKeyImport.inspect(TestSecret(KeyFixture.text(name))) }
        #expect(throws: SSHKeyImportError.dsaKey) {
            try SSHKeyImport.read(TestSecret(KeyFixture.text(name)), passphrase: nil)
        }
    }

    /// RSA keys under 2048 bits are refused, saying how many they have: in OpenSSH's format before
    /// any passphrase, from its public key; in PEM once libssh has read it.
    @Test func rsaKeyUnder2048BitsIsRefused() {
        #expect(throws: SSHKeyImportError.rsaKeyTooSmall(bits: 1024)) {
            try SSHKeyImport.inspect(TestSecret(KeyFixture.text("rsa-1024-openssh")))
        }
        #expect(throws: SSHKeyImportError.rsaKeyTooSmall(bits: 1024)) {
            try SSHKeyImport.read(TestSecret(KeyFixture.text("rsa-1024-pem")), passphrase: nil)
        }
        #expect(
            SSHKeyImportError.rsaKeyTooSmall(bits: 1024).description
                == "This RSA key has 1024 bits, too few to be safe. Shello imports RSA keys of 2048 bits or more.")
    }

    @Test func ecdsaP521KeyIsRefused() {
        #expect(throws: SSHKeyImportError.unsupportedAlgorithm("ECDSA P-521")) {
            try SSHKeyImport.read(TestSecret(KeyFixture.text("ecdsa-p521-openssh")), passphrase: nil)
        }
    }

    /// A public key, pasted where the private key goes, says so: a `.pub` file's line, and PEM's and
    /// RFC 4716's public keys.
    @Test(arguments: [
        KeyFixture.text("ed25519.pub"), KeyFixture.text("rsa-3072.pub"), "  " + KeyFixture.text("ecdsa-p384.pub"),
        "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAGb9ECWmEzf6FQbrBZ9w7lshQhqowtrbLDFw4rXAxZuE=\n-----END PUBLIC KEY-----\n",
        "---- BEGIN SSH2 PUBLIC KEY ----\nAAAAC3NzaC1lZDI1NTE5AAAAIPvgEvQu86QqJttkdsQxdc7v7JlPMil/uW4h7lDS3MKC\n---- END SSH2 PUBLIC KEY ----\n",
    ])
    func publicKeyIsRefused(_ text: String) {
        #expect(throws: SSHKeyImportError.publicKey) { try SSHKeyImport.read(TestSecret(text), passphrase: nil) }
    }

    @Test func puttyKeyIsRefused() {
        let putty = "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: key\nPublic-Lines: 2\n"
        #expect(throws: SSHKeyImportError.puttyKey) { try SSHKeyImport.read(TestSecret(putty), passphrase: nil) }
    }

    /// Text that is no key, or a key whose text was cut short or altered, is unreadable.
    @Test(arguments: [
        "", "not a key", "-----BEGIN OPENSSH PRIVATE KEY-----\n-----END OPENSSH PRIVATE KEY-----\n",
        "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n",
        String(KeyFixture.text("ed25519-openssh").prefix(200)),
        KeyFixture.text("ecdsa-p256-pem").replacing("A", with: "B"),
        String(repeating: "x", count: KeyText.maximumLength + 1),
    ])
    func textThatIsNoKeyIsUnreadable(_ text: String) {
        #expect(throws: SSHKeyImportError.unreadable) { try SSHKeyImport.read(TestSecret(text), passphrase: nil) }
    }

    // MARK: - Helpers

    private static func format(of variant: KeyFixture.Variant) -> SSHKeyFile.Format {
        switch variant.format {
        case .openSSH: .openSSH
        case .pem: .pem
        case .pkcs8: .pkcs8
        }
    }

    private static func algorithm(of key: KeyFixture.Key) -> SSHKeyAlgorithm {
        switch key {
        case .ed25519: .ed25519
        case .ecdsaP256: .ecdsaP256
        case .ecdsaP384: .ecdsaP384
        case .rsa3072: .rsa
        }
    }

    /// The key of the fixture's `.pub` file, in SSH's wire format.
    private static func publicKey(of key: KeyFixture.Key) -> [UInt8] {
        let base64 = key.publicKeyLine.split(separator: " ")[1]
        return Array(Data(base64Encoded: String(base64)) ?? Data())
    }

    private static func bytes(of secret: any SecretBytes) -> [UInt8] {
        unsafe secret.withUnsafeBytes { unsafe Array($0) }
    }
}
