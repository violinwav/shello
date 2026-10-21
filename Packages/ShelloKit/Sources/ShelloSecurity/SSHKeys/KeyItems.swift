import Foundation
import LocalAuthentication

/// The Keychain items behind `SSHKeyStore`, one per SSH key (STACK section 7.3). An item holds:
/// - the key's record, everything about the key but the private key, which reads without
///   authentication, so that keys can be listed while nobody is asked anything;
/// - the key data: the Secure Enclave's blob of the key, or the Ed25519 private key, which reads
///   only with the right context.
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
    }

    /// The stored values of `SigningPolicy`. They never change either.
    private enum PolicyValue: String {
        case whileUnlocked
        case everyUse
    }

    init(_ key: SSHKey) {
        id = key.id
        kind =
            switch key.kind {
            case .secureEnclave: KindValue.secureEnclave.rawValue
            case .ed25519: KindValue.ed25519.rawValue
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

    /// The key this record holds, or nil for a kind or policy this version of Shello does not know,
    /// for example one a newer version wrote.
    var key: SSHKey? {
        guard let kindValue = KindValue(rawValue: kind), let policyValue = PolicyValue(rawValue: signingPolicy) else {
            return nil
        }
        let kind: SSHKey.Kind =
            switch kindValue {
            case .secureEnclave: .secureEnclave
            case .ed25519: .ed25519
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
}
