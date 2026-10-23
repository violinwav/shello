import Foundation
import LocalAuthentication

/// The Keychain items behind `SSHKeyStore`, one per SSH key (STACK section 7.3). An item holds:
/// - the key's record, everything about the key but the private key, which reads without
///   authentication, so that keys can be listed while nobody is asked anything;
/// - the key data: the Secure Enclave's blob of the key, or the private key of an Ed25519 or an
///   imported key, which reads only with the right context.
///
/// `SystemKeyItems` keeps them in the iOS Keychain; `MemoryKeyItems` keeps them in memory, for tests,
/// previews and UI tests.
protocol KeyItems: Sendable {
    /// Adds the item of the key `record.id`, which holds `keyData`. With `requiresUserPresence`, the
    /// key data reads only with a context on which the user authenticated, with Face ID, Touch ID or
    /// the passcode.
    func add(_ record: KeyRecord, keyData: Secret, requiresUserPresence: Bool) throws
    /// Every item's record, in no particular order. No key data is read.
    func records() throws -> [KeyRecord]
    /// The key data of the item `id`, read with `context`, or nil if there is no such item.
    func keyData(of id: UUID, context: LAContext) throws -> Secret?
    /// Removes the item `id`, if there is one.
    func remove(_ id: UUID) throws
}

/// An SSH key's record in its Keychain item: everything in `SSHKey`, and never the private key. The
/// Keychain lets anyone with access to the item read the record without authentication, so the
/// private key is the item's data instead, which it guards.
struct KeyRecord: Codable, Hashable, Sendable {
    /// The version of the record's format, for a later Shello that changes it.
    static let currentVersion = 1

    var version = KeyRecord.currentVersion
    var id: UUID
    /// `SSHKey.Kind`, as one of `KindValue`'s raw values.
    var kind: String
    /// An imported key's algorithm, as one of `AlgorithmValue`'s raw values; nil, and left out of the
    /// record, for the kinds of key Shello makes, whose kind gives their algorithm. A Shello from
    /// before imported keys skips the records of the kind `imported`, which it does not know.
    var algorithm: String?
    /// `SigningPolicy`, as one of `PolicyValue`'s raw values.
    var signingPolicy: String
    var comment: String
    /// The public key in SSH's wire format.
    var publicKey: Data
    var createdAt: Date

    /// The stored values of `SSHKey.Kind`. They are part of the Keychain's contents: they never change.
    private enum KindValue: String {
        case secureEnclave
        case ed25519
        case imported
    }

    /// The stored values of `SSHKeyAlgorithm`, for imported keys. They never change either.
    private enum AlgorithmValue: String {
        case ecdsaP256
        case ecdsaP384
        case ed25519
        case rsa
    }

    /// The stored values of `SigningPolicy`. They never change either.
    private enum PolicyValue: String {
        case whileUnlocked
        case everyUse
    }

    init(_ key: SSHKey) {
        id = key.id
        switch key.kind {
        case .secureEnclave:
            kind = KindValue.secureEnclave.rawValue
        case .ed25519:
            kind = KindValue.ed25519.rawValue
        case .imported(let algorithm):
            kind = KindValue.imported.rawValue
            self.algorithm =
                switch algorithm {
                case .ecdsaP256: AlgorithmValue.ecdsaP256.rawValue
                case .ecdsaP384: AlgorithmValue.ecdsaP384.rawValue
                case .ed25519: AlgorithmValue.ed25519.rawValue
                case .rsa: AlgorithmValue.rsa.rawValue
                }
        }
        signingPolicy =
            switch key.signingPolicy {
            case .whileUnlocked: PolicyValue.whileUnlocked.rawValue
            case .everyUse: PolicyValue.everyUse.rawValue
            }
        comment = key.comment
        publicKey = key.publicKey.wireRepresentation
        createdAt = key.createdAt
    }

    /// The key this record holds, or nil for a kind, algorithm or policy this version of Shello does
    /// not know, for example one a newer version wrote.
    var key: SSHKey? {
        guard let kind = storedKind, let policyValue = PolicyValue(rawValue: signingPolicy) else {
            return nil
        }
        let policy: SigningPolicy =
            switch policyValue {
            case .whileUnlocked: .whileUnlocked
            case .everyUse: .everyUse
            }
        return SSHKey(
            id: id, comment: comment, kind: kind, signingPolicy: policy,
            publicKey: SSHPublicKey(algorithm: kind.algorithm, wireRepresentation: publicKey), createdAt: createdAt)
    }

    /// The kind `kind` and `algorithm` hold, or nil for one this version does not know.
    private var storedKind: SSHKey.Kind? {
        switch KindValue(rawValue: kind) {
        case .secureEnclave: return .secureEnclave
        case .ed25519: return .ed25519
        case .imported:
            switch algorithm.flatMap(AlgorithmValue.init(rawValue:)) {
            case .ecdsaP256: return .imported(.ecdsaP256)
            case .ecdsaP384: return .imported(.ecdsaP384)
            case .ed25519: return .imported(.ed25519)
            case .rsa: return .imported(.rsa)
            case nil: return nil
            }
        case nil: return nil
        }
    }
}
