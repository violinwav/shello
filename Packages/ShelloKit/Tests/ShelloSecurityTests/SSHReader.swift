import CryptoKit
import Foundation
import Security

/// Reads the SSH wire format (RFC 4251 section 5), the way a server or `ssh-keygen` reads what
/// Shello writes. Tests only: Shello itself writes SSH's wire format, and reads little of it.
struct SSHReader {
    struct Truncated: Error {}

    private var bytes: ArraySlice<UInt8>

    init(_ data: Data) {
        bytes = ArraySlice(data)
    }

    var isAtEnd: Bool { bytes.isEmpty }

    mutating func readUInt32() throws -> UInt32 {
        guard bytes.count >= 4 else { throw Truncated() }
        defer { bytes = bytes.dropFirst(4) }
        return bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func readString() throws -> Data {
        let count = Int(try readUInt32())
        guard bytes.count >= count else { throw Truncated() }
        defer { bytes = bytes.dropFirst(count) }
        return Data(bytes.prefix(count))
    }

    mutating func readText() throws -> String {
        String(decoding: try readString(), as: UTF8.self)
    }
}

/// An SSH signature taken apart: its algorithm's name and the signature itself.
struct ParsedSSHSignature {
    let algorithm: String
    let blob: Data

    init(_ wireRepresentation: Data) throws {
        var reader = SSHReader(wireRepresentation)
        algorithm = try reader.readText()
        blob = try reader.readString()
        guard reader.isAtEnd else { throw SSHReader.Truncated() }
    }

    /// Whether the signature's algorithm is one the key of `line` signs with: its own, or for an
    /// RSA key, `rsa-sha2-256` or `rsa-sha2-512` (RFC 8332), never `ssh-rsa`'s SHA-1.
    func isMade(by line: ParsedOpenSSHLine) -> Bool {
        line.algorithm == "ssh-rsa"
            ? ["rsa-sha2-256", "rsa-sha2-512"].contains(algorithm) : algorithm == line.algorithm
    }

    /// The `mpint`s r and s of an ECDSA signature, as SSH wrote them.
    func ecdsaMPInts() throws -> (r: Data, s: Data) {
        var reader = SSHReader(blob)
        let r = try reader.readString()
        let s = try reader.readString()
        guard reader.isAtEnd else { throw SSHReader.Truncated() }
        return (r, s)
    }

    /// The ECDSA P-256 signature, for CryptoKit to verify: r and s as 32 bytes each.
    func ecdsaSignature() throws -> P256.Signing.ECDSASignature {
        let (r, s) = try ecdsaMPInts()
        return try P256.Signing.ECDSASignature(rawRepresentation: Self.fixedWidth(r, 32) + Self.fixedWidth(s, 32))
    }

    /// The ECDSA P-384 signature, for CryptoKit to verify: r and s as 48 bytes each.
    func p384Signature() throws -> P384.Signing.ECDSASignature {
        let (r, s) = try ecdsaMPInts()
        return try P384.Signing.ECDSASignature(rawRepresentation: Self.fixedWidth(r, 48) + Self.fixedWidth(s, 48))
    }

    /// Whether the RSA signature is `key`'s of `data`, with the hash its algorithm names.
    func isValidRSASignature(for data: Data, by key: SecKey) throws -> Bool {
        let algorithm: SecKeyAlgorithm =
            switch self.algorithm {
            case "rsa-sha2-256": .rsaSignatureMessagePKCS1v15SHA256
            case "rsa-sha2-512": .rsaSignatureMessagePKCS1v15SHA512
            default: throw SSHReader.Truncated()
            }
        return SecKeyVerifySignature(key, algorithm, data as CFData, blob as CFData, nil)
    }

    /// An `mpint` of at most `width` bytes of magnitude, as exactly `width` bytes.
    private static func fixedWidth(_ mpint: Data, _ width: Int) -> Data {
        let magnitude = mpint.drop { $0 == 0 }
        return Data(repeating: 0, count: width - magnitude.count) + magnitude
    }
}

/// An OpenSSH public key line taken apart: `<algorithm> <base64 of the key> <comment>`.
struct ParsedOpenSSHLine {
    let algorithm: String
    let wireRepresentation: Data
    let comment: String

    init(_ line: String) throws {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2, let key = Data(base64Encoded: String(fields[1])) else { throw SSHReader.Truncated() }
        algorithm = String(fields[0])
        wireRepresentation = key
        comment = fields.count == 3 ? String(fields[2]) : ""
    }

    /// The P-256 public key of an `ecdsa-sha2-nistp256` line.
    func p256PublicKey() throws -> P256.Signing.PublicKey {
        var reader = SSHReader(wireRepresentation)
        guard try reader.readText() == "ecdsa-sha2-nistp256", try reader.readText() == "nistp256" else {
            throw SSHReader.Truncated()
        }
        return try P256.Signing.PublicKey(x963Representation: try reader.readString())
    }

    /// The P-384 public key of an `ecdsa-sha2-nistp384` line.
    func p384PublicKey() throws -> P384.Signing.PublicKey {
        var reader = SSHReader(wireRepresentation)
        guard try reader.readText() == "ecdsa-sha2-nistp384", try reader.readText() == "nistp384" else {
            throw SSHReader.Truncated()
        }
        return try P384.Signing.PublicKey(x963Representation: try reader.readString())
    }

    /// The Ed25519 public key of an `ssh-ed25519` line.
    func ed25519PublicKey() throws -> Curve25519.Signing.PublicKey {
        var reader = SSHReader(wireRepresentation)
        guard try reader.readText() == "ssh-ed25519" else { throw SSHReader.Truncated() }
        return try Curve25519.Signing.PublicKey(rawRepresentation: try reader.readString())
    }

    /// The RSA public key of an `ssh-rsa` line, as Security takes it: PKCS #1's `RSAPublicKey`,
    /// `SEQUENCE { modulus INTEGER, publicExponent INTEGER }`, whose integers SSH writes as DER does.
    func rsaPublicKey() throws -> SecKey {
        var reader = SSHReader(wireRepresentation)
        guard try reader.readText() == "ssh-rsa" else { throw SSHReader.Truncated() }
        let exponent = try reader.readString()
        let modulus = try reader.readString()
        let integers = Self.der(0x02, modulus) + Self.der(0x02, exponent)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(Self.der(0x30, integers) as CFData, attributes as CFDictionary, nil)
        else { throw SSHReader.Truncated() }
        return key
    }

    /// A DER element: `tag`, the length of `contents`, then `contents`.
    private static func der(_ tag: UInt8, _ contents: Data) -> Data {
        var length = [UInt8(truncatingIfNeeded: contents.count)]
        if contents.count >= 0x80 {
            length = Array([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: contents.count >> $0) }.drop { $0 == 0 })
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag] + length) + contents
    }
}
