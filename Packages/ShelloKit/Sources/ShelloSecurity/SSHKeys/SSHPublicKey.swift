import CryptoKit
import Foundation
import ShelloModel

/// The public half of an SSH key (README section 13), in the forms that servers and people use:
/// SSH's wire format, which an SSH agent lists; OpenSSH's one-line text, which `authorized_keys`
/// holds; and the SHA-256 fingerprint. Shello writes them itself (STACK section 7.3), byte for byte
/// as `ssh-keygen` does.
public struct SSHPublicKey: Hashable, Sendable {
    public let algorithm: SSHKeyAlgorithm
    /// The key in SSH's wire format (RFC 4253 section 6.6): the algorithm's name, then the key.
    public let wireRepresentation: Data

    init(algorithm: SSHKeyAlgorithm, wireRepresentation: Data) {
        self.algorithm = algorithm
        self.wireRepresentation = wireRepresentation
    }

    /// An ECDSA P-256 key (RFC 5656 section 3.1): `ecdsa-sha2-nistp256`, the curve's name, and the
    /// point, uncompressed.
    init(_ key: P256.Signing.PublicKey) {
        var writer = SSHWriter()
        writer.writeString(SSHKeyAlgorithm.ecdsaP256.name)
        writer.writeString("nistp256")
        writer.writeString(key.x963Representation)
        self.init(algorithm: .ecdsaP256, wireRepresentation: writer.data)
    }

    /// An ECDSA P-384 key (RFC 5656 section 3.1): `ecdsa-sha2-nistp384`, the curve's name, and the
    /// point, uncompressed.
    init(_ key: P384.Signing.PublicKey) {
        var writer = SSHWriter()
        writer.writeString(SSHKeyAlgorithm.ecdsaP384.name)
        writer.writeString("nistp384")
        writer.writeString(key.x963Representation)
        self.init(algorithm: .ecdsaP384, wireRepresentation: writer.data)
    }

    /// An Ed25519 key (RFC 8709 section 4): `ssh-ed25519`, then the key's 32 bytes.
    init(_ key: Curve25519.Signing.PublicKey) {
        var writer = SSHWriter()
        writer.writeString(SSHKeyAlgorithm.ed25519.name)
        writer.writeString(key.rawRepresentation)
        self.init(algorithm: .ed25519, wireRepresentation: writer.data)
    }

    /// An RSA key (RFC 4253 section 6.6): `ssh-rsa`, the public exponent, then the modulus, each an
    /// `mpint`, given as unsigned big-endian bytes.
    init(rsaModulus modulus: some Collection<UInt8>, exponent: some Collection<UInt8>) {
        var writer = SSHWriter()
        writer.writeString(SSHKeyAlgorithm.rsa.name)
        writer.writeMPInt(unsignedBigEndian: exponent)
        writer.writeMPInt(unsignedBigEndian: modulus)
        self.init(algorithm: .rsa, wireRepresentation: writer.data)
    }

    /// The key as one line of `authorized_keys`, as `ssh-keygen` writes a `.pub` file without its
    /// line break: the algorithm's name, the key in base64, then `comment`, if there is one.
    public func openSSHLine(comment: String) -> String {
        let line = "\(algorithm.name) \(wireRepresentation.base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// The SHA-256 fingerprint, as `ssh-keygen -l` shows it: `SHA256:`, then the hash of the key in
    /// base64, without padding.
    public var fingerprint: String {
        let hash = Data(SHA256.hash(data: wireRepresentation)).base64EncodedString()
        return "SHA256:" + hash.prefix { $0 != "=" }
    }

    /// How many bits an RSA key's modulus has, such as 3072, as `ssh-keygen -l` counts them; nil for
    /// the other algorithms, whose curve fixes their size.
    public var rsaBits: Int? {
        guard algorithm == .rsa else { return nil }
        var bytes = wireRepresentation[...]
        // The algorithm's name and the exponent come first.
        guard Self.dropString(from: &bytes), Self.dropString(from: &bytes), let modulus = Self.string(in: bytes),
            let first = modulus.first(where: { $0 != 0 })
        else { return nil }
        let leadingZeros = modulus.prefix { $0 == 0 }.count
        return (modulus.count - leadingZeros - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    /// Drops the `string` at the start of `bytes`, and returns whether there was one.
    private static func dropString(from bytes: inout Data.SubSequence) -> Bool {
        guard let string = string(in: bytes) else { return false }
        bytes = bytes[string.endIndex...]
        return true
    }

    /// The contents of the `string` at the start of `bytes`: a `uint32` length, then that many
    /// bytes. Nil if `bytes` ends first.
    private static func string(in bytes: Data.SubSequence) -> Data.SubSequence? {
        guard bytes.count >= 4 else { return nil }
        let length = bytes.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        let start = bytes.startIndex + 4
        guard bytes.endIndex - start >= length else { return nil }
        return bytes[start..<start + length]
    }
}
