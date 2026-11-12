import Foundation

/// The key a server proves its identity with (GLOSSARY): what the user is asked to trust on the
/// first connection to a server, and what every later connection must match (README section 3).
public struct HostKey: Hashable, Sendable {
    /// The key's type as SSH names it, such as `ssh-ed25519`, `ecdsa-sha2-nistp256` or `ssh-rsa`.
    public let algorithm: String
    /// The key in SSH's wire format (RFC 4253 section 6.6). Two host keys are the same key when
    /// these bytes are.
    public let wireRepresentation: Data
    /// The SHA-256 fingerprint as OpenSSH writes it: `SHA256:`, then the hash in base64 without
    /// padding.
    public let fingerprint: String

    public init(algorithm: String, wireRepresentation: Data, fingerprint: String) {
        self.algorithm = algorithm
        self.wireRepresentation = wireRepresentation
        self.fingerprint = fingerprint
    }

    /// The key's type as `ssh-keygen -l` shows it, such as `ED25519`, `ECDSA` or `RSA`, which is
    /// how people compare it with what a server's administrator reads out.
    public var typeName: String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case "ssh-ed448": "ED448"
        case "sk-ssh-ed25519@openssh.com": "ED25519-SK"
        case "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA-SK"
        default: algorithm.hasPrefix("ecdsa-sha2-") ? "ECDSA" : algorithm.uppercased()
        }
    }
}

/// The host key the user accepted for a server on the first connection to it (GLOSSARY). Every
/// later connection to the server must present the same key: a different one is a changed host key,
/// which blocks the connection (README section 3).
public struct TrustedHostKey: Hashable, Sendable {
    public let key: HostKey
    /// When the user trusted the key.
    public let trustedAt: Date

    public init(key: HostKey, trustedAt: Date) {
        self.key = key
        self.trustedAt = trustedAt
    }
}
