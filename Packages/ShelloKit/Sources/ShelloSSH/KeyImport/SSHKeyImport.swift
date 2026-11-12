import CLibSSH
import Foundation
import ShelloModel

/// Reads imported keys (GLOSSARY, README section 13): private keys in OpenSSH's format or in PEM,
/// PKCS #8 included, with or without a passphrase, as the user pastes them or picks their file.
/// libssh reads and decrypts them (`ssh_pki_import_privkey_base64`, STACK section 7.3), and hands
/// the private key over as `ImportedKeyMaterial`, for ShelloSecurity to keep in the Keychain and sign
/// with through Shello's SSH agent.
///
/// Shello imports Ed25519, ECDSA P-256 and P-384, and RSA keys of at least 2048 bits, which sign with
/// SHA-256 or SHA-512 only. It refuses DSA, which OpenSSH 10 removed and libssh 0.12 does not have,
/// smaller RSA keys, ECDSA P-521 and security keys, each with a sentence that says why, before it
/// asks for a passphrase where the text tells.
///
/// The text and the passphrase are read in place and never copied, and the private key goes into a
/// buffer that is overwritten once it is let go. Neither is ever logged.
public enum SSHKeyImport {
    /// The fewest bits an RSA key may have: since 2014, NIST allows no smaller key for signatures
    /// (SP 800-131A). OpenSSH still makes keys of 1024 bits, but by default of 3072.
    public static let minimumRSABits = 2048

    /// What `text` holds, read without its passphrase, which it tells whether it needs. A key that
    /// Shello will not import is refused here already when the text tells, as for a DSA key.
    /// - Throws: `SSHKeyImportError` for a text that is not a private key Shello imports.
    public static func inspect(_ text: some SecretBytes) throws(SSHKeyImportError) -> SSHKeyFile {
        let keyText = unsafe text.withUnsafeBytes { unsafe KeyText($0) }
        switch keyText {
        case .openSSH(let isEncrypted, let publicKey):
            try check(publicKey)
            return SSHKeyFile(format: .openSSH, isEncrypted: isEncrypted)
        case .pem(.dsa, _):
            throw .dsaKey
        case .pem(_, let isEncrypted):
            return SSHKeyFile(format: .pem, isEncrypted: isEncrypted)
        case .pkcs8(let isEncrypted):
            return SSHKeyFile(format: .pkcs8, isEncrypted: isEncrypted)
        case .publicKey:
            throw .publicKey
        case .putty:
            throw .puttyKey
        case .unknown:
            throw .unreadable
        }
    }

    /// Reads the private key in `text`, decrypting it with `passphrase` if it is encrypted; the
    /// passphrase of a key that is not encrypted is left alone. Encrypted OpenSSH keys take a while,
    /// as their passphrase goes through bcrypt, so call this off the main actor.
    /// - Throws: `SSHKeyImportError.passphraseRequired` for an encrypted key without a passphrase,
    ///   `.wrongPassphrase` if it does not decrypt the key, or the reason Shello does not import it.
    public static func read(
        _ text: some SecretBytes, passphrase: (any SecretBytes)?
    ) throws(SSHKeyImportError) -> ImportedKeyMaterial {
        let file = try inspect(text)
        let passphrase = file.isEncrypted ? passphrase.flatMap(Self.nonEmpty) : nil
        guard !file.isEncrypted || passphrase != nil else { throw .passphraseRequired }
        guard LibSSH.isInitialized else { throw .unreadable }

        var imported: OpaquePointer?
        // Set when libssh asks for a passphrase after all, which `refusePrompt` refuses: OpenSSL
        // would ask on a terminal otherwise.
        var asked: Int32 = 0
        let result = unsafe text.withUnsafeBytes { text in
            unsafe withUnsafeMutablePointer(to: &asked) { asked in
                unsafe Self.withCString(passphrase) { passphrase in
                    // The text's bytes are followed by a zero byte (`SecretBytes`).
                    guard let text = unsafe text.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                        return SSH_ERROR
                    }
                    return unsafe ssh_pki_import_privkey_base64(
                        text, passphrase, Self.refusePrompt, UnsafeMutableRawPointer(asked), &imported)
                }
            }
        }
        guard result == SSH_OK, let key = unsafe imported else {
            if file.isEncrypted { throw .wrongPassphrase }
            throw asked != 0 ? .passphraseRequired : .unreadable
        }
        defer { unsafe ssh_key_free(key) }

        let algorithm = try unsafe Self.algorithm(of: key)
        let publicKey = try unsafe Self.publicKey(of: key)
        if algorithm == .rsa, let bits = PublicKeySummary(wireRepresentation: publicKey)?.rsaBits,
            bits < minimumRSABits
        {
            throw .rsaKeyTooSmall(bits: bits)
        }
        let privateKey = try unsafe Self.privateKey(of: key, algorithm: algorithm)
        return ImportedKeyMaterial(algorithm: algorithm, publicKey: publicKey, privateKey: privateKey)
    }

    // MARK: - Checks

    /// Refuses the public key of an OpenSSH private key that Shello does not import, before the
    /// passphrase is asked for.
    private static func check(_ publicKey: PublicKeySummary) throws(SSHKeyImportError) {
        switch publicKey.type {
        case "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384":
            return
        case "ssh-rsa":
            if let bits = publicKey.rsaBits, bits < minimumRSABits { throw .rsaKeyTooSmall(bits: bits) }
        case "ssh-dss":
            throw .dsaKey
        case "ecdsa-sha2-nistp521":
            throw .unsupportedAlgorithm("ECDSA P-521")
        case let type where type.hasPrefix("sk-"):
            throw .securityKey
        default:
            throw .unreadable
        }
    }

    /// The algorithm of the key libssh read.
    private static func algorithm(of key: OpaquePointer) throws(SSHKeyImportError) -> SSHKeyAlgorithm {
        switch unsafe ssh_key_type(key) {
        case SSH_KEYTYPE_ED25519: return .ed25519
        case SSH_KEYTYPE_ECDSA_P256: return .ecdsaP256
        case SSH_KEYTYPE_ECDSA_P384: return .ecdsaP384
        case SSH_KEYTYPE_RSA: return .rsa
        case SSH_KEYTYPE_ECDSA_P521: throw .unsupportedAlgorithm("ECDSA P-521")
        case SSH_KEYTYPE_SK_ECDSA, SSH_KEYTYPE_SK_ED25519: throw .securityKey
        default: throw .unreadable
        }
    }

    // MARK: - The key's halves

    /// The public key, in SSH's wire format, which libssh hands out in base64 only.
    private static func publicKey(of key: OpaquePointer) throws(SSHKeyImportError) -> [UInt8] {
        var base64: UnsafeMutablePointer<CChar>?
        guard unsafe ssh_pki_export_pubkey_base64(key, &base64) == SSH_OK, let text = unsafe base64 else {
            throw .unreadable
        }
        defer { unsafe ssh_string_free_char(text) }
        guard let wireRepresentation = unsafe Data(base64Encoded: String(cString: text)) else { throw .unreadable }
        return Array(wireRepresentation)
    }

    /// The private key, in the form `ImportedKeyMaterial` describes. libssh hands it over as PKCS
    /// #8 in PEM, which OpenSSL writes; it is decoded into a buffer of its own, where the private key
    /// is found in place, and libssh's text is overwritten before it is freed.
    private static func privateKey(
        of key: OpaquePointer, algorithm: SSHKeyAlgorithm
    ) throws(SSHKeyImportError) -> SecretBuffer {
        var exported: UnsafeMutablePointer<CChar>?
        guard
            unsafe ssh_pki_export_privkey_base64_format(key, nil, nil, nil, &exported, SSH_FILE_FORMAT_PEM)
                == SSH_OK,
            let pem = unsafe exported
        else { throw .unreadable }
        let length = unsafe strlen(pem)
        defer {
            _ = unsafe memset_s(pem, length, 0, length)
            unsafe ssh_string_free_char(pem)
        }
        let text = unsafe UnsafeRawBufferPointer(start: pem, count: length)
        guard let armor = unsafe PEMArmor(text), armor.label == "PRIVATE KEY" else { throw .unreadable }

        let der: SecretBuffer
        do {
            der = try unsafe SecretBuffer(capacity: armor.body.count / 4 * 3 + 3) { buffer in
                var decoder = unsafe Base64Decoder(text[armor.body].makeIterator())
                var count = 0
                while count < buffer.count, let byte = unsafe decoder.next() {
                    unsafe buffer[count] = byte
                    count += 1
                }
                guard unsafe !decoder.isInvalid, unsafe decoder.next() == nil else { throw DERError.malformed }
                return count
            }
        } catch {
            throw .unreadable
        }
        return try unsafe der.withUnsafeBytes { bytes throws(SSHKeyImportError) in
            let pkcs8: PKCS8PrivateKey
            do {
                pkcs8 = try unsafe PKCS8PrivateKey(der: bytes)
            } catch {
                throw .unreadable
            }
            let privateKey = unsafe bytes[pkcs8.privateKey]
            switch (algorithm, pkcs8.algorithm) {
            case (.rsa, .rsa), (.ed25519, .ed25519):
                return unsafe SecretBuffer(copying: privateKey)
            case (.ecdsaP256, .ec):
                return try unsafe Self.scalar(privateKey, size: 32)
            case (.ecdsaP384, .ec):
                return try unsafe Self.scalar(privateKey, size: 48)
            default:
                throw .unreadable
            }
        }
    }

    /// An ECDSA private scalar as exactly `size` bytes, big-endian, as CryptoKit takes it: zeros are
    /// added in front of a shorter one, and dropped from the front of a longer one.
    private static func scalar(
        _ bytes: Slice<UnsafeRawBufferPointer>, size: Int
    ) throws(SSHKeyImportError) -> SecretBuffer {
        let significant = unsafe bytes.drop { $0 == 0 }
        guard unsafe significant.count <= size else { throw .unreadable }
        return unsafe SecretBuffer(capacity: size) { buffer in
            // The buffer starts out as zeros.
            let padding = unsafe size - significant.count
            for unsafe(offset, byte) in unsafe significant.enumerated() {
                unsafe buffer[padding + offset] = byte
            }
            return size
        }
    }

    // MARK: - Helpers

    /// The C function libssh calls when it needs a passphrase it was not given, as for a key that
    /// turned out to be encrypted after all: it says no, and notes that it was asked in the `Int32`
    /// that `userdata` points at.
    private static let refusePrompt: ssh_auth_callback = { _, _, _, _, _, userdata in
        unsafe userdata?.storeBytes(of: 1, as: Int32.self)
        return -1
    }

    /// `secret`, or nil if it has no bytes, as an empty passphrase field leaves it.
    private static func nonEmpty(_ secret: any SecretBytes) -> (any SecretBytes)? {
        unsafe secret.withUnsafeBytes { unsafe $0.isEmpty } ? nil : secret
    }

    /// Calls `body` with the secret as a C string, or with nil when there is none: a secret's bytes
    /// are followed by a zero byte (`SecretBytes`).
    private static func withCString<Result>(
        _ secret: (any SecretBytes)?, _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let secret else { return body(nil) }
        return unsafe secret.withUnsafeBytes { bytes in
            unsafe body(bytes.baseAddress?.assumingMemoryBound(to: CChar.self))
        }
    }
}

/// What a private key's text says about the key, read before its passphrase.
public struct SSHKeyFile: Hashable, Sendable {
    /// The format a private key is in.
    public enum Format: Hashable, Sendable {
        /// OpenSSH's own: `-----BEGIN OPENSSH PRIVATE KEY-----`.
        case openSSH
        /// PEM, OpenSSL's traditional format, such as `-----BEGIN RSA PRIVATE KEY-----`.
        case pem
        /// PKCS #8: `-----BEGIN PRIVATE KEY-----`, or `ENCRYPTED PRIVATE KEY`.
        case pkcs8
    }

    public let format: Format
    /// Whether the key is encrypted, and is read with its passphrase.
    public let isEncrypted: Bool
}

/// Why a private key was not imported. Each case says it in a sentence the app can show; none ever
/// holds the key or its passphrase.
public enum SSHKeyImportError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The key is encrypted, and no passphrase was given.
    case passphraseRequired
    /// The passphrase does not decrypt the key.
    case wrongPassphrase
    /// A DSA key: too weak, removed from OpenSSH 10, and not in libssh 0.12.
    case dsaKey
    /// A key of this algorithm, such as ECDSA P-521, which Shello does not import.
    case unsupportedAlgorithm(String)
    /// A key that lives on a security key (FIDO), which Shello cannot use yet (README section 13).
    case securityKey
    /// An RSA key of fewer than `SSHKeyImport.minimumRSABits`.
    case rsaKeyTooSmall(bits: Int)
    /// A public key, where the private key was expected.
    case publicKey
    /// A key in PuTTY's format.
    case puttyKey
    /// Nothing that libssh reads as a private key.
    case unreadable

    public var description: String {
        switch self {
        case .passphraseRequired: "This key is encrypted. Enter its passphrase to import it."
        case .wrongPassphrase: "The passphrase isn’t right. Check it and try again."
        case .dsaKey:
            "DSA keys can’t be imported: they’re too weak, and OpenSSH no longer accepts them. Import an Ed25519, "
                + "ECDSA or RSA key instead."
        case .unsupportedAlgorithm(let name):
            "\(name) keys can’t be imported. Shello imports Ed25519, ECDSA P-256 and P-384, and RSA keys."
        case .securityKey: "Keys on a security key can’t be imported yet."
        case .rsaKeyTooSmall(let bits):
            "This RSA key has \(bits) bits, too few to be safe. Shello imports RSA keys of "
                + "\(SSHKeyImport.minimumRSABits) bits or more."
        case .publicKey: "This is a public key. Import the private key instead: the file without “.pub” at the end."
        case .puttyKey: "PuTTY keys can’t be imported. Convert the key to OpenSSH’s format in PuTTYgen first."
        case .unreadable:
            "This isn’t a private key that Shello can read. Shello imports private keys in OpenSSH’s format and in PEM."
        }
    }
}

/// The sentence of `description` wherever the error is shown through `localizedDescription`.
extension SSHKeyImportError: LocalizedError {
    public var errorDescription: String? { description }
}
