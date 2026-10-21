import CryptoKit
import Foundation

/// Reads the SSH wire format (RFC 4251 section 5), the way a server or `ssh-keygen` reads what
/// Shello writes. Tests only: Shello itself writes SSH's wire format, and reads none of it yet.
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

    /// The `mpint`s r and s of an ECDSA signature, as SSH wrote them.
    func ecdsaMPInts() throws -> (r: Data, s: Data) {
        var reader = SSHReader(blob)
        let r = try reader.readString()
        let s = try reader.readString()
        guard reader.isAtEnd else { throw SSHReader.Truncated() }
        return (r, s)
    }

    /// The ECDSA signature, for CryptoKit to verify: r and s as 32 bytes each.
    func ecdsaSignature() throws -> P256.Signing.ECDSASignature {
        let (r, s) = try ecdsaMPInts()
        return try P256.Signing.ECDSASignature(rawRepresentation: Self.fixedWidth(r) + Self.fixedWidth(s))
    }

    /// An `mpint` of at most 32 bytes of magnitude, as exactly 32 bytes.
    private static func fixedWidth(_ mpint: Data) -> Data {
        let magnitude = mpint.drop { $0 == 0 }
        return Data(repeating: 0, count: 32 - magnitude.count) + magnitude
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

    /// The Ed25519 public key of an `ssh-ed25519` line.
    func ed25519PublicKey() throws -> Curve25519.Signing.PublicKey {
        var reader = SSHReader(wireRepresentation)
        guard try reader.readText() == "ssh-ed25519" else { throw SSHReader.Truncated() }
        return try Curve25519.Signing.PublicKey(rawRepresentation: try reader.readString())
    }
}
