import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Synchronization

/// The Secure Enclave, as `SSHKeyStore` uses it (STACK section 7.3). It makes ECDSA P-256 keys that
/// sign only for a user who is present, and hands each one out as an opaque blob, which only this
/// device's Secure Enclave can use. `SystemEnclave` is the device's; `MemoryEnclave` stands in for it
/// in tests and previews.
protocol Enclave: Sendable {
    /// Whether keys can be made here.
    var isAvailable: Bool { get }
    /// Makes a key and returns its blob and its public key.
    func makeKey() throws -> (blob: Data, publicKey: P256.Signing.PublicKey)
    /// Signs `data`, hashed with SHA-256, with the key `blob`, on `context`.
    func signature(for data: Data, blob: Data, context: LAContext) throws -> P256.Signing.ECDSASignature
}

/// The device's Secure Enclave, through CryptoKit.
struct SystemEnclave: Enclave {
    var isAvailable: Bool {
        #if targetEnvironment(simulator)
            // The simulator reports a Secure Enclave, but makes no key whose use needs the user's
            // presence: LocalAuthentication answers "This call is not supported on iOS Simulator."
            false
        #else
            SecureEnclave.isAvailable
        #endif
    }

    /// The key needs the user's presence for each signature (`.privateKeyUsage` plus
    /// `.userPresence`), which an authenticated context provides.
    func makeKey() throws -> (blob: Data, publicKey: P256.Signing.PublicKey) {
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            accessControl: try deviceOnlyAccessControl([.privateKeyUsage, .userPresence]))
        return (key.dataRepresentation, key.publicKey)
    }

    func signature(for data: Data, blob: Data, context: LAContext) throws -> P256.Signing.ECDSASignature {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        return try key.signature(for: data)
    }
}

/// Stands in for the Secure Enclave where there is none, in tests, previews and UI tests: its keys
/// are ordinary P-256 keys in memory, which it names by blobs of its own. It asks nobody: any
/// context signs.
final class MemoryEnclave: Enclave {
    let isAvailable: Bool
    private let keys = Mutex<[Data: P256.Signing.PrivateKey]>([:])

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    func makeKey() throws -> (blob: Data, publicKey: P256.Signing.PublicKey) {
        guard isAvailable else { throw SSHKeyError.secureEnclaveUnavailable }
        let key = P256.Signing.PrivateKey()
        return (insert(key), key.publicKey)
    }

    func signature(for data: Data, blob: Data, context: LAContext) throws -> P256.Signing.ECDSASignature {
        guard let key = keys.withLock({ $0[blob] }) else { throw UnknownBlob() }
        return try key.signature(for: data)
    }

    /// A blob that names none of the enclave's keys.
    struct UnknownBlob: Error {}

    /// Takes `key` in, and returns its blob.
    func insert(_ key: P256.Signing.PrivateKey) -> Data {
        let blob = Data(UUID().uuidString.utf8)
        keys.withLock { $0[blob] = key }
        return blob
    }
}
