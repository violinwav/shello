import ShelloModel
import ShelloSecurity

// How SSH keys and their properties read on screen and to VoiceOver.

extension SSHKey.Kind {
    var displayName: String {
        switch self {
        case .secureEnclave: "Secure Enclave"
        case .ed25519: "Ed25519"
        case .imported(let algorithm): algorithm.displayName
        }
    }

    /// Where the private key lives.
    var storage: String {
        switch self {
        case .secureEnclave: "Secure Enclave"
        case .ed25519, .imported: "Keychain"
        }
    }

    /// What the key is and where its private key lives, under its name.
    var summary: String {
        switch self {
        case .secureEnclave: "ECDSA P-256 in the Secure Enclave"
        case .ed25519: "Ed25519 in the Keychain"
        case .imported(let algorithm): "Imported \(algorithm.displayName) key in the Keychain"
        }
    }

    /// Why to choose the kind, under the choice of a new key's type.
    var explanation: String {
        switch self {
        case .secureEnclave:
            "ECDSA P-256. The private key never leaves the Secure Enclave, the chip that guards this device’s keys."
        case .ed25519:
            "For servers that need Ed25519. The private key stays in this device’s Keychain."
        case .imported:
            "A key you brought from elsewhere. Its private key stays in this device’s Keychain."
        }
    }
}

extension SSHKeyAlgorithm {
    var displayName: String {
        switch self {
        case .ecdsaP256: "ECDSA P-256"
        case .ed25519: "Ed25519"
        case .ecdsaP384: "ECDSA P-384"
        case .rsa: "RSA"
        }
    }
}

extension SigningPolicy {
    var displayName: String {
        switch self {
        case .whileUnlocked: "While Shello Is Unlocked"
        case .everyUse: "On Every Use"
        }
    }
}

extension SSHKey {
    /// The key's algorithm, with an RSA key's size, which tells RSA keys apart: "RSA 3072".
    var algorithmName: String {
        guard let bits = publicKey.rsaBits else { return kind.algorithm.displayName }
        return "\(kind.algorithm.displayName) \(bits)"
    }

    /// What VoiceOver reads after the key's name, and what its row shows under it: its kind, whether
    /// it is imported, and that it asks on every use.
    var summary: String {
        let kind = kind.isImported ? "Imported \(algorithmName) key in the Keychain" : kind.summary
        return signingPolicy == .everyUse ? "\(kind), asks on every use" : kind
    }
}
