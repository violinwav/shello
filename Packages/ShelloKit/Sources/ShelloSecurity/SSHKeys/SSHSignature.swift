import CryptoKit
import Foundation
import ShelloModel

/// Signatures in SSH's wire format, as SSH sends them and an SSH agent returns them
/// (draft-ietf-sshm-ssh-agent section 4.5.1): the algorithm's name, then the signature, each in a
/// `string`.
enum SSHSignature {
    /// An ECDSA P-256 signature (RFC 5656 section 3.1.2): `ecdsa-sha2-nistp256`, then `mpint r`
    /// and `mpint s` together in one `string`.
    static func ecdsaP256(_ signature: P256.Signing.ECDSASignature) -> Data {
        ecdsa(.ecdsaP256, rawRepresentation: signature.rawRepresentation)
    }

    /// An ECDSA P-384 signature (RFC 5656 section 3.1.2): `ecdsa-sha2-nistp384`, then `mpint r`
    /// and `mpint s` together in one `string`.
    static func ecdsaP384(_ signature: P384.Signing.ECDSASignature) -> Data {
        ecdsa(.ecdsaP384, rawRepresentation: signature.rawRepresentation)
    }

    /// An Ed25519 signature (RFC 8709 section 6): `ssh-ed25519`, then the signature's 64 bytes.
    static func ed25519(_ signature: Data) -> Data {
        var writer = SSHWriter()
        writer.writeString(SSHKeyAlgorithm.ed25519.name)
        writer.writeString(signature)
        return writer.data
    }

    /// An RSA signature (RFC 8332 section 3): `rsa-sha2-256` or `rsa-sha2-512`, then the signature,
    /// as long as the key's modulus.
    static func rsa(_ hash: RSAHash, _ signature: Data) -> Data {
        var writer = SSHWriter()
        writer.writeString(hash.signatureAlgorithm)
        writer.writeString(signature)
        return writer.data
    }

    /// r and then s, half of `rawRepresentation` each, as `mpint`s in a `string` after the
    /// algorithm's name.
    private static func ecdsa(_ algorithm: SSHKeyAlgorithm, rawRepresentation raw: Data) -> Data {
        let half = raw.count / 2
        var blob = SSHWriter()
        blob.writeMPInt(unsignedBigEndian: raw.prefix(half))
        blob.writeMPInt(unsignedBigEndian: raw.dropFirst(half))
        var writer = SSHWriter()
        writer.writeString(algorithm.name)
        writer.writeString(blob.data)
        return writer.data
    }
}

/// The hash an RSA key signs with (RFC 8332): SHA-256 or SHA-512, as the sign request's flags
/// choose. Never SHA-1, the hash of `ssh-rsa` signatures, which OpenSSH 8.8 and later refuse.
enum RSAHash: Hashable, Sendable {
    case sha256
    case sha512

    /// The hash `flags` ask for, as OpenSSH's agent reads them: SHA-256 if its flag is set, else
    /// SHA-512 if its flag is; nil for neither, which asks for SHA-1.
    init?(_ flags: SSHSignatureFlags) {
        if flags.contains(.rsaSHA256) {
            self = .sha256
        } else if flags.contains(.rsaSHA512) {
            self = .sha512
        } else {
            return nil
        }
    }

    /// The name SSH gives the signature.
    var signatureAlgorithm: String {
        switch self {
        case .sha256: "rsa-sha2-256"
        case .sha512: "rsa-sha2-512"
        }
    }
}

/// What an SSH agent's sign request asks for besides the data (draft-ietf-sshm-ssh-agent section
/// 4.5.1). The flags choose an RSA key's hash. ECDSA and Ed25519 keys have one signature algorithm
/// each, so the flags change nothing for them, as in OpenSSH's agent.
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
