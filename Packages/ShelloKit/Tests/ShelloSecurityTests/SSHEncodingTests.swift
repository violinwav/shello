import CryptoKit
import Foundation
import Testing

@testable import ShelloSecurity

/// SSH's wire format (RFC 4251 section 5), with the examples of the RFC itself.
struct SSHWriterTests {
    @Test func uint32IsBigEndian() {
        var writer = SSHWriter()
        writer.write(0x2973_7FFE)
        #expect(writer.data == Data([0x29, 0x73, 0x7F, 0xFE]))
    }

    @Test func stringIsItsLengthThenItsBytes() {
        var writer = SSHWriter()
        writer.writeString("testing")
        #expect(writer.data == Data([0, 0, 0, 7, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6E, 0x67]))
    }

    /// RFC 4251 section 5: 0, 0x9a378f9b2e332a7, 0x80, and 0xdeadbeef written as mpints.
    @Test(arguments: [
        ("", "00000000"),
        ("09a378f9b2e332a7", "0000000809a378f9b2e332a7"),
        ("80", "000000020080"),
        ("deadbeef", "0000000500deadbeef"),
    ])
    func mpintMatchesTheRFCsExamples(number: String, encoded: String) {
        var writer = SSHWriter()
        writer.writeMPInt(unsignedBigEndian: Data(hex: number))
        #expect(writer.data == Data(hex: encoded))
    }

    /// CryptoKit gives r and s as 32 bytes each, leading zeros and all.
    @Test func mpintDropsLeadingZerosButKeepsOneBeforeATopBit() {
        var writer = SSHWriter()
        writer.writeMPInt(unsignedBigEndian: Data(hex: "000000ff"))
        writer.writeMPInt(unsignedBigEndian: Data(hex: "00007f"))
        writer.writeMPInt(unsignedBigEndian: Data(hex: "0000"))
        #expect(writer.data == Data(hex: "0000000200ff" + "000000017f" + "00000000"))
    }
}

/// Public keys and fingerprints, byte for byte as `ssh-keygen` writes them (STACK section 7.3).
struct SSHPublicKeyTests {
    @Test func ed25519KeyMatchesSSHKeygen() throws {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: SSHKeygenVectors.Ed25519.privateKey)
        #expect(privateKey.publicKey.rawRepresentation == SSHKeygenVectors.Ed25519.rawPublicKey)

        let publicKey = SSHPublicKey(privateKey.publicKey)

        #expect(publicKey.algorithm == .ed25519)
        #expect(publicKey.openSSHLine(comment: SSHKeygenVectors.Ed25519.comment) == SSHKeygenVectors.Ed25519.publicKey)
        #expect(publicKey.fingerprint == SSHKeygenVectors.Ed25519.fingerprint)
    }

    @Test func ecdsaKeyMatchesSSHKeygen() throws {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: SSHKeygenVectors.ECDSA.privateKey)

        let publicKey = SSHPublicKey(privateKey.publicKey)

        #expect(publicKey.algorithm == .ecdsaP256)
        #expect(publicKey.openSSHLine(comment: SSHKeygenVectors.ECDSA.comment) == SSHKeygenVectors.ECDSA.publicKey)
        #expect(publicKey.fingerprint == SSHKeygenVectors.ECDSA.fingerprint)
    }

    /// `ssh-keygen` leaves the comment out, with the space before it, when there is none.
    @Test func lineWithoutACommentEndsWithTheKey() throws {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: SSHKeygenVectors.Ed25519.privateKey)

        let line = SSHPublicKey(privateKey.publicKey).openSSHLine(comment: "")

        #expect(line == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea")
    }
}

/// Signatures in SSH's wire format, checked against signatures `ssh-keygen` made.
struct SSHSignatureTests {
    /// Encoding r and s of each of `ssh-keygen`'s signatures gives back its bytes: an `mpint` with
    /// a zero byte before a top bit, and a shorter one for a number with a leading zero byte.
    @Test(arguments: SSHKeygenVectors.ECDSA.signatures)
    func ecdsaSignatureMatchesSSHKeygenByteForByte(vector: SSHKeygenVectors.ECDSA.Signature) throws {
        let parsed = try ParsedSSHSignature(vector.wireRepresentation)
        let (r, s) = try parsed.ecdsaMPInts()
        #expect(r.count == vector.rLength)
        #expect(s.count == vector.sLength)

        let encoded = SSHSignature.ecdsaP256(try parsed.ecdsaSignature())

        #expect(encoded == vector.wireRepresentation)
    }

    /// What Shello reads as r and s in OpenSSH's signatures is a valid signature of what
    /// `ssh-keygen` signed, so both sides agree on the format.
    @Test(arguments: SSHKeygenVectors.ECDSA.signatures)
    func sshKeygensECDSASignatureVerifies(vector: SSHKeygenVectors.ECDSA.Signature) throws {
        let publicKey = try ParsedOpenSSHLine(SSHKeygenVectors.ECDSA.publicKey).p256PublicKey()
        let parsed = try ParsedSSHSignature(vector.wireRepresentation)

        #expect(parsed.algorithm == "ecdsa-sha2-nistp256")
        #expect(publicKey.isValidSignature(try parsed.ecdsaSignature(), for: SSHKeygenVectors.signedData))
    }

    @Test func ed25519SignatureMatchesSSHKeygen() throws {
        let publicKey = try ParsedOpenSSHLine(SSHKeygenVectors.Ed25519.publicKey).ed25519PublicKey()
        let parsed = try ParsedSSHSignature(SSHKeygenVectors.Ed25519.signature)
        #expect(parsed.algorithm == "ssh-ed25519")
        #expect(publicKey.isValidSignature(parsed.blob, for: SSHKeygenVectors.signedData))

        #expect(SSHSignature.ed25519(parsed.blob) == SSHKeygenVectors.Ed25519.signature)
    }

    /// CryptoKit's Ed25519 signatures are randomised, unlike OpenSSH's, so Shello's differ from
    /// `ssh-keygen`'s; they verify against the same public key all the same.
    @Test func ed25519SignatureOfCryptoKitVerifiesAgainstSSHKeygensKey() throws {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: SSHKeygenVectors.Ed25519.privateKey)
        let publicKey = try ParsedOpenSSHLine(SSHKeygenVectors.Ed25519.publicKey).ed25519PublicKey()

        let signature = SSHSignature.ed25519(try privateKey.signature(for: SSHKeygenVectors.signedData))

        let parsed = try ParsedSSHSignature(signature)
        #expect(parsed.algorithm == "ssh-ed25519")
        #expect(parsed.blob.count == 64)
        #expect(publicKey.isValidSignature(parsed.blob, for: SSHKeygenVectors.signedData))
    }
}
