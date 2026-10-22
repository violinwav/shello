// The libssh build linked into the app: OpenSSL as its crypto backend, zlib from the iOS SDK.
// Vendor/build.sh builds both from verified source; docs/spec/STACK.md section 7.2.
import CLibSSH

/// The version and algorithms of the libssh linked into Shello. Connections offer those of the
/// algorithm policy (`AlgorithmPolicy`), which must be among these.
public enum LibSSH {
    /// libssh's version and backends, for example `0.12.2/openssl/zlib`.
    public static var version: String {
        unsafe String(cString: ssh_version(0))
    }

    /// The key exchange algorithms this build supports, in libssh's order.
    public static var keyExchanges: [String] {
        supportedMethods(SSH_KEX)
    }

    /// The ciphers this build supports, in libssh's order.
    static var ciphers: [String] {
        supportedMethods(SSH_CRYPT_C_S)
    }

    /// The MACs this build supports, in libssh's order.
    static var macs: [String] {
        supportedMethods(SSH_MAC_C_S)
    }

    /// The host key and signature algorithms this build supports, certificates included, in
    /// libssh's order.
    static var publicKeyAlgorithms: [String] {
        supportedMethods(SSH_HOSTKEYS)
    }

    /// A statically linked libssh must be initialised once before anything else is called.
    static let isInitialized = ssh_init() == SSH_OK

    private static func supportedMethods(_ type: ssh_kex_types_e) -> [String] {
        guard isInitialized, let methods = unsafe ssh_get_supported_methods(type) else { return [] }
        return unsafe String(cString: methods).split(separator: ",").map(String.init)
    }
}
