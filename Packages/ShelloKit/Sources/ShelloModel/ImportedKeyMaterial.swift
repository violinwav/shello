/// An imported key's private key (GLOSSARY: Imported key), decrypted: how it goes from ShelloSSH,
/// whose libssh reads the user's file or paste, to ShelloSecurity, which keeps it in the Keychain
/// (README section 13, STACK section 7.3), without either module depending on the other, as
/// `SecretBytes` carries a password the other way.
public struct ImportedKeyMaterial: Sendable {
    public let algorithm: SSHKeyAlgorithm
    /// The public key in SSH's wire format (RFC 4253 section 6.6), as libssh read it.
    public let publicKey: [UInt8]
    /// The private key, in the form Apple's frameworks take it: Ed25519's 32-byte seed, an ECDSA
    /// key's private scalar of 32 or 48 bytes, or an RSA key's PKCS #1 `RSAPrivateKey` in DER. Its
    /// buffer is overwritten once the last reference to it goes.
    public let privateKey: any SecretBytes

    public init(algorithm: SSHKeyAlgorithm, publicKey: [UInt8], privateKey: any SecretBytes) {
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}
