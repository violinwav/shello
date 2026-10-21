import CryptoKit
import Foundation

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

    /// An Ed25519 key (RFC 8709 section 4): `ssh-ed25519`, then the key's 32 bytes.
    init(_ key: Curve25519.Signing.PublicKey) {
        var writer = SSHWriter()
        writer.writeString(SSHKeyAlgorithm.ed25519.name)
        writer.writeString(key.rawRepresentation)
        self.init(algorithm: .ed25519, wireRepresentation: writer.data)
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
}

/// The SSH key algorithms of the keys Shello makes.
public enum SSHKeyAlgorithm: Hashable, Sendable, CaseIterable {
    /// ECDSA on the NIST P-256 curve, with SHA-256 (RFC 5656): the only kind of key the Secure
    /// Enclave makes.
    case ecdsaP256
    /// Ed25519 (RFC 8709).
    case ed25519

    /// The algorithm's name in SSH, which starts its public keys and its signatures.
    public var name: String {
        switch self {
        case .ecdsaP256: "ecdsa-sha2-nistp256"
        case .ed25519: "ssh-ed25519"
        }
    }
}
