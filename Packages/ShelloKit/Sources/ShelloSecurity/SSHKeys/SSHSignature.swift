import CryptoKit
import Foundation

/// Signatures in SSH's wire format, as SSH sends them and an SSH agent returns them
/// (draft-ietf-sshm-ssh-agent section 4.5.1): the algorithm's name, then the signature, each in a
/// `string`.
enum SSHSignature {
    /// An ECDSA P-256 signature (RFC 5656 section 3.1.2): `ecdsa-sha2-nistp256`, then `mpint r`
    /// and `mpint s` together in one `string`.
    static func ecdsaP256(_ signature: P256.Signing.ECDSASignature) -> Data {
        // r and then s, 32 bytes each.
        let raw = signature.rawRepresentation
        var blob = SSHWriter()
        blob.writeMPInt(unsignedBigEndian: raw.prefix(32))
        blob.writeMPInt(unsignedBigEndian: raw.dropFirst(32))
        var writer = SSHWriter()
        writer.writeString(SSHKeyAlgorithm.ecdsaP256.name)
        writer.writeString(blob.data)
        return writer.data
    }

    /// An Ed25519 signature (RFC 8709 section 6): `ssh-ed25519`, then the signature's 64 bytes.
    static func ed25519(_ signature: Data) -> Data {
        var writer = SSHWriter()
        writer.writeString(SSHKeyAlgorithm.ed25519.name)
        writer.writeString(signature)
        return writer.data
    }
}

/// What an SSH agent's sign request asks for besides the data (draft-ietf-sshm-ssh-agent section
/// 4.5.1). The flags choose an RSA key's hash. The ECDSA and Ed25519 keys that Shello makes have one
/// signature algorithm each, so the flags change nothing for them, as in OpenSSH's agent.
public struct SSHSignatureFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// `SSH_AGENT_RSA_SHA2_256`: an RSA key signs with SHA-256, as `rsa-sha2-256`.
    public static let rsaSHA256 = SSHSignatureFlags(rawValue: 0x02)
    /// `SSH_AGENT_RSA_SHA2_512`: an RSA key signs with SHA-512, as `rsa-sha2-512`.
    public static let rsaSHA512 = SSHSignatureFlags(rawValue: 0x04)
}
