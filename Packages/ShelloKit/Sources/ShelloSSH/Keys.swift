import CLibSSH
import Foundation
import ShelloModel

extension HostKey {
    /// The public key `key` as Shello shows and trusts it, with the fingerprint libssh computes.
    init(libssh key: OpaquePointer) throws(SSHError) {
        guard let algorithm = unsafe ssh_key_type_to_char(ssh_key_type(key)) else {
            throw .protocolError("the server’s host key has an unknown type")
        }
        // libssh hands out the key's wire format as base64 only.
        var base64: UnsafeMutablePointer<CChar>?
        guard unsafe ssh_pki_export_pubkey_base64(key, &base64) == SSH_OK, let text = unsafe base64 else {
            throw .protocolError("the server’s host key could not be read")
        }
        let wireRepresentation = unsafe Data(base64Encoded: String(cString: text))
        unsafe ssh_string_free_char(text)
        guard let wireRepresentation else { throw .protocolError("the server’s host key could not be read") }

        var hash: UnsafeMutablePointer<UInt8>?
        var hashLength = 0
        guard unsafe ssh_get_publickey_hash(key, SSH_PUBLICKEY_HASH_SHA256, &hash, &hashLength) == SSH_OK,
            let digest = unsafe hash
        else {
            throw .protocolError("the server’s host key fingerprint could not be computed")
        }
        let sha256 = unsafe Data(bytes: digest, count: hashLength)
        unsafe ssh_clean_pubkey_hash(&hash)

        self.init(
            algorithm: unsafe String(cString: algorithm), wireRepresentation: wireRepresentation,
            fingerprint: Self.fingerprint(sha256: sha256))
    }

    /// The fingerprint as OpenSSH writes it: `SHA256:`, then the hash in base64 without its padding.
    static func fingerprint(sha256: Data) -> String {
        "SHA256:" + sha256.base64EncodedString().prefix { $0 != "=" }
    }
}

/// A private key that libssh read from its text, in OpenSSH's or PEM's format, for signing in with an
/// imported key (README section 13). It lives on its connection's queue and is freed there.
final class ImportedKey {
    let key: Handle

    /// Reads the key from `text`, decrypting it with `passphrase` if it is encrypted.
    /// - Throws: `SSHError.invalidKey` if the text holds no key libssh can read, or the passphrase
    ///   is missing or wrong.
    init(text: some SecretBytes, passphrase: (any SecretBytes)?) throws(SSHError) {
        var imported: OpaquePointer?
        let result = unsafe text.withUnsafeBytes { text in
            unsafe Self.withCString(passphrase) { passphrase in
                guard let text = unsafe text.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                    return SSH_ERROR
                }
                return unsafe ssh_pki_import_privkey_base64(text, passphrase, nil, nil, &imported)
            }
        }
        guard result == SSH_OK, let imported = unsafe imported else { throw .invalidKey }
        key = unsafe Handle(imported)
    }

    deinit {
        unsafe ssh_key_free(key.pointer)
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
