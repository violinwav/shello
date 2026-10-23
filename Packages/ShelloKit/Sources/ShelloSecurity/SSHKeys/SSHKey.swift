import Foundation
import ShelloModel

/// An SSH key on this device (GLOSSARY): a generated key, which Shello made here and which never
/// leaves the device (README section 13, ADR 0003), or an imported key, which the user brought from
/// elsewhere.
///
/// It holds what is safe to show and share: the key's name, kind and signing policy, and its public
/// key. The private key stays in the Secure Enclave or the Keychain, and no code outside
/// ShelloSecurity can read it: `SSHKeyStore` signs with it instead.
public struct SSHKey: Identifiable, Hashable, Sendable {
    /// Where the private key lives and where it came from, which decide its algorithm.
    public enum Kind: Hashable, Sendable {
        /// ECDSA P-256 inside the Secure Enclave, which never lets the private key out: the default.
        /// The Secure Enclave makes no other kind of key.
        case secureEnclave
        /// Ed25519 in the Keychain, on this device only, for servers that need it.
        case ed25519
        /// An imported key, of `algorithm`, in the Keychain, on this device only. Shello does not
        /// make it: it comes from `SSHKeyStore.importKey(_:comment:signingPolicy:)`.
        case imported(SSHKeyAlgorithm)

        /// The kinds of key Shello makes, the default first: `SSHKeyStore.kinds` says which this
        /// device can.
        public static let generated: [Kind] = [.secureEnclave, .ed25519]

        public var algorithm: SSHKeyAlgorithm {
            switch self {
            case .secureEnclave: .ecdsaP256
            case .ed25519: .ed25519
            case .imported(let algorithm): algorithm
            }
        }

        /// Whether a key of this kind is an imported key, rather than one Shello made.
        public var isImported: Bool {
            if case .imported = self { true } else { false }
        }
    }

    public let id: UUID
    /// The key's name. It ends the public key as its comment, which tells keys apart in a server's
    /// `authorized_keys`.
    public let comment: String
    public let kind: Kind
    public let signingPolicy: SigningPolicy
    public let publicKey: SSHPublicKey
    /// When the key was made, or imported.
    public let createdAt: Date

    init(
        id: UUID, comment: String, kind: Kind, signingPolicy: SigningPolicy, publicKey: SSHPublicKey, createdAt: Date
    ) {
        self.id = id
        self.comment = comment
        self.kind = kind
        self.signingPolicy = signingPolicy
        self.publicKey = publicKey
        self.createdAt = createdAt
    }

    /// The public key with the key's name as its comment, as one line of `authorized_keys`: what
    /// Shello copies and shares.
    public var openSSHPublicKey: String {
        publicKey.openSSHLine(comment: comment)
    }

    /// Whether `comment` can end a public key: it must stay on one line of `authorized_keys`, so it
    /// holds no line break or other control character.
    public static func isValidComment(_ comment: String) -> Bool {
        !comment.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

/// When an SSH key may sign (README section 13).
public enum SigningPolicy: Hashable, Sendable, CaseIterable {
    /// While Shello is unlocked: inside the unlock window, with no prompt of its own. The default.
    case whileUnlocked
    /// On every use: Face ID, Touch ID or the passcode before each signature, so that every
    /// connection and every reconnect with the key asks.
    case everyUse

    /// The policy of a new key until the user chooses another.
    public static let standard = SigningPolicy.whileUnlocked
}

/// Why the SSH key store could not do what it was asked.
public enum SSHKeyError: Error, Equatable, CustomStringConvertible {
    /// There is no SSH key with this identifier on this device: it was deleted, or made on another
    /// device.
    case keyNotFound(UUID)
    /// This device has no Secure Enclave that Shello can make keys in, as in the iOS Simulator.
    case secureEnclaveUnavailable
    /// The comment holds a line break or another control character, which `authorized_keys` cannot.
    case invalidComment
    /// Shello does not make keys of this kind: imported keys come from elsewhere.
    case cannotMake(SSHKey.Kind)
    /// The private key of an imported key is not the private key of its public key, or one that
    /// Apple's frameworks cannot use.
    case mismatchedKeyPair
    /// An RSA key was asked for a signature with SHA-1 (`ssh-rsa`), which Shello never makes:
    /// OpenSSH 8.8 and later refuse it, and Shello signs with SHA-256 or SHA-512 only (RFC 8332).
    case rsaSHA1Refused

    public var description: String {
        switch self {
        case .keyNotFound: "The SSH key isn’t on this device."
        case .secureEnclaveUnavailable: "This device can’t make Secure Enclave keys."
        case .invalidComment: "The name of an SSH key must be one line, without control characters."
        case .cannotMake: "Shello can’t make this kind of SSH key: imported keys come from elsewhere."
        case .mismatchedKeyPair: "The SSH key can’t be used: its private key doesn’t match its public key."
        case .rsaSHA1Refused: "Shello signs with RSA keys using SHA-256 or SHA-512 only, never SHA-1."
        }
    }
}
