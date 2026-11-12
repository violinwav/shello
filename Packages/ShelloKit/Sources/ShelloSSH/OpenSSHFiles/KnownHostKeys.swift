import CLibSSH
import CLibSSHInternal
import Foundation
import ShelloModel

/// What the import from a `known_hosts` file (README section 3) needs beyond the parser, which uses
/// the standard library only (`KnownHosts`): the host key of an entry, read by libssh as a
/// connection reads the server's, and the HMAC-SHA1 that hashed names are made with. Both come from
/// libssh and its OpenSSL, the only C libraries Shello's code reaches (STACK section 4).
public enum KnownHostKeys {
    /// The host key on `entry`, as libssh reads it and as a connection to the server would show
    /// it: the same type, wire format and fingerprint, so that an imported key is the trusted key
    /// a connection finds.
    /// - Throws: `SSHError.invalidKey` if libssh cannot read the key.
    public static func hostKey(of entry: KnownHosts.Entry) throws(SSHError) -> HostKey {
        let type = unsafe ssh_key_type_from_name(entry.keyType)
        guard type != SSH_KEYTYPE_UNKNOWN else { throw .invalidKey }
        var key: OpaquePointer?
        guard unsafe ssh_pki_import_pubkey_base64(entry.keyBase64, type, &key) == SSH_OK, let key = unsafe key else {
            throw .invalidKey
        }
        defer { unsafe ssh_key_free(key) }
        do {
            return try unsafe HostKey(libssh: key)
        } catch {
            throw .invalidKey
        }
    }

    /// The HMAC-SHA1 of `message`, keyed with `key`, as OpenSSH hashes a name in `known_hosts`
    /// (`HashKnownHosts`): the key is the name's salt. Nil if libssh's OpenSSL fails.
    ///
    /// SHA-1 is what the file's format uses; Shello's connections never do (README section 4).
    public static func hmacSHA1(key: [UInt8], message: [UInt8]) -> [UInt8]? {
        let context = unsafe key.withUnsafeBytes { key in
            unsafe hmac_init(key.baseAddress, key.count, SSH_HMAC_SHA1)
        }
        guard let context = unsafe context else { return nil }
        let updated = unsafe message.withUnsafeBytes { message in
            unsafe hmac_update(context, message.baseAddress, message.count)
        }
        var digest = [UInt8](repeating: 0, count: 20)
        var length = digest.count
        let finished = unsafe digest.withUnsafeMutableBytes { digest in
            unsafe hmac_final(context, digest.baseAddress?.assumingMemoryBound(to: UInt8.self), &length)
        }
        guard updated == 1, finished == 1, length == 20 else { return nil }
        return digest
    }
}
