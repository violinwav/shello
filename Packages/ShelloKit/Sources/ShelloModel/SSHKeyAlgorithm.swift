/// The algorithms of the SSH keys Shello signs in with (README section 4): those of the keys it makes,
/// and those of the keys it imports.
public enum SSHKeyAlgorithm: Hashable, Sendable, CaseIterable {
    /// ECDSA on the NIST P-256 curve, with SHA-256 (RFC 5656): the only kind of key the Secure
    /// Enclave makes.
    case ecdsaP256
    /// Ed25519 (RFC 8709).
    case ed25519
    /// ECDSA on the NIST P-384 curve, with SHA-384 (RFC 5656). Imported keys only.
    case ecdsaP384
    /// RSA, which signs with SHA-256 or SHA-512 (RFC 8332) and never with SHA-1. Imported keys only.
    case rsa

    /// The algorithm's name in SSH, which starts its public keys. ECDSA and Ed25519 signatures start
    /// with it too; RSA's go by `rsa-sha2-256` or `rsa-sha2-512` instead.
    public var name: String {
        switch self {
        case .ecdsaP256: "ecdsa-sha2-nistp256"
        case .ed25519: "ssh-ed25519"
        case .ecdsaP384: "ecdsa-sha2-nistp384"
        case .rsa: "ssh-rsa"
        }
    }
}
