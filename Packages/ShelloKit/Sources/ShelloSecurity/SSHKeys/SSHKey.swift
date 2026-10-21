import Foundation

/// An SSH key that Shello made on this device: a generated key (GLOSSARY.md), which never leaves it
/// (README section 13, ADR 0003).
///
/// It holds what is safe to show and share: the key's name, kind and signing policy, and its public
/// key. The private key stays in the Secure Enclave or the Keychain, and no code outside
/// ShelloSecurity can read it: `SSHKeyStore` signs with it instead.
public struct SSHKey: Identifiable, Hashable, Sendable {
    /// Where the private key lives, which decides its algorithm.
    public enum Kind: Hashable, Sendable, CaseIterable {
        /// ECDSA P-256 inside the Secure Enclave, which never lets the private key out: the default.
        /// The Secure Enclave makes no other kind of key.
        case secureEnclave
        /// Ed25519 in the Keychain, on this device only, for servers that need it.
        case ed25519

        public var algorithm: SSHKeyAlgorithm {
            switch self {
            case .secureEnclave: .ecdsaP256
            case .ed25519: .ed25519
            }
        }
    }

    public let id: UUID
    /// The key's name. It ends the public key as its comment, which tells keys apart in a server's
    /// `authorized_keys`.
    public let comment: String
    public let kind: Kind
    public let signingPolicy: SigningPolicy
    public let publicKey: SSHPublicKey
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

    public var description: String {
        switch self {
        case .keyNotFound: "The SSH key isn’t on this device."
        case .secureEnclaveUnavailable: "This device can’t make Secure Enclave keys."
        case .invalidComment: "The name of an SSH key must be one line, without control characters."
        }
    }
}
