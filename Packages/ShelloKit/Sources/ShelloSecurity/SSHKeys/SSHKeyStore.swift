import CryptoKit
import Foundation
import LocalAuthentication

/// The SSH keys on this device (README section 13, STACK section 7.3), and the one place that signs
/// with them: the SSH agent signs through `sign(_:with:flags:reason:)`.
///
/// Shello makes two kinds of generated key, which never leave the device (ADR 0003):
/// - ECDSA P-256 in the Secure Enclave, the default. The key needs the user's presence for each
///   signature (`.privateKeyUsage` plus `.userPresence`), and its blob, which only this device's
///   Secure Enclave can use, is a Keychain item.
/// - Ed25519, for servers that need it. The private key is a Keychain item, which reads only with
///   the user's presence.
///
/// Both items are `WhenUnlockedThisDeviceOnly` and never synchronizable, so they are in no backup
/// that leaves the device, and never sync. The store hands out no private key: it returns `SSHKey`s,
/// which hold public data only, and signatures.
///
/// A key signs as its `SigningPolicy` says:
/// - While Shello is unlocked, with the unlock window's context, on which the user authenticated at
///   app lock. While the window is closed, signing fails with `UnlockWindowClosed`; the SSH agent
///   opens the window first.
/// - On every use, with a fresh context on which the user authenticates for this one signature.
///
/// The iOS Simulator has no Secure Enclave that Shello can use (`offersSecureEnclave`), so there it
/// makes Ed25519 keys only.
public struct SSHKeyStore: Sendable {
    private let items: any KeyItems
    private let enclave: any Enclave
    private let unlockWindow: UnlockWindow
    private let authentication: any Authentication

    /// The device's SSH keys, in its Keychain and Secure Enclave. Keys that sign while Shello is
    /// unlocked use `unlockWindow`'s context; keys that sign on every use ask through
    /// `authentication`.
    public init(unlockWindow: UnlockWindow, authentication: some Authentication = LocalAuthentication()) {
        self.init(
            items: SystemKeyItems(), enclave: SystemEnclave(), unlockWindow: unlockWindow,
            authentication: authentication)
    }

    /// SSH keys in memory, for tests, SwiftUI previews and UI tests: they go when the store goes.
    /// Without `secureEnclave`, the store makes Ed25519 keys only, as in the iOS Simulator. With it,
    /// a stand-in makes the Secure Enclave's kind of key, as an ordinary P-256 key in memory.
    public static func inMemory(
        unlockWindow: UnlockWindow, authentication: some Authentication = LocalAuthentication(),
        secureEnclave: Bool = false
    ) -> SSHKeyStore {
        SSHKeyStore(
            items: MemoryKeyItems(), enclave: MemoryEnclave(isAvailable: secureEnclave), unlockWindow: unlockWindow,
            authentication: authentication)
    }

    init(items: some KeyItems, enclave: some Enclave, unlockWindow: UnlockWindow, authentication: some Authentication) {
        self.items = items
        self.enclave = enclave
        self.unlockWindow = unlockWindow
        self.authentication = authentication
    }

    /// Whether this device can make Secure Enclave keys. The iOS Simulator cannot.
    public var offersSecureEnclave: Bool {
        enclave.isAvailable
    }

    /// The kinds of key this device can make, the default first.
    public var kinds: [SSHKey.Kind] {
        offersSecureEnclave ? [.secureEnclave, .ed25519] : [.ed25519]
    }

    /// Every SSH key on this device, by name. Reading them asks nobody anything.
    /// - Throws: `KeychainError`.
    public func keys() throws -> [SSHKey] {
        try items.records().compactMap(\.key).sorted { first, second in
            switch first.comment.localizedStandardCompare(second.comment) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: (first.createdAt, first.id.uuidString) < (second.createdAt, second.id.uuidString)
            }
        }
    }

    /// The SSH key with this identifier, or nil if it is not on this device.
    /// - Throws: `KeychainError`.
    public func key(id: SSHKey.ID) throws -> SSHKey? {
        try items.records().first { $0.id == id }?.key
    }

    /// Makes a new SSH key of `kind`, named `comment`, that signs as `signingPolicy` says.
    /// Surrounding whitespace is left out of the name.
    /// - Throws: `UnlockWindowClosed` while app lock is engaged; `SSHKeyError.invalidComment` for a
    ///   name with a line break, `.secureEnclaveUnavailable` for a Secure Enclave key on a device
    ///   that cannot make one; `KeychainError`, or what the Secure Enclave reported.
    @concurrent
    public func generate(_ kind: SSHKey.Kind, comment: String, signingPolicy: SigningPolicy) async throws -> SSHKey {
        guard unlockWindow.isOpen else { throw UnlockWindowClosed() }
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHKey.isValidComment(comment) else { throw SSHKeyError.invalidComment }
        switch kind {
        case .secureEnclave:
            guard enclave.isAvailable else { throw SSHKeyError.secureEnclaveUnavailable }
            let (blob, publicKey) = try enclave.makeKey()
            let key = newKey(kind, comment: comment, signingPolicy: signingPolicy, publicKey: SSHPublicKey(publicKey))
            // The Secure Enclave asks for the user's presence itself, and the blob is useless
            // anywhere else, so the item needs no access control of its own.
            try items.add(KeyRecord(key), keyData: Secret(copying: blob), requiresUserPresence: false)
            return key
        case .ed25519:
            let privateKey = Curve25519.Signing.PrivateKey()
            var rawRepresentation = privateKey.rawRepresentation
            // The key goes to the Keychain in a `Secret`, which is overwritten once it is released.
            // This copy, CryptoKit's, is cleared too.
            defer { rawRepresentation.resetBytes(in: rawRepresentation.indices) }
            let key = newKey(
                kind, comment: comment, signingPolicy: signingPolicy, publicKey: SSHPublicKey(privateKey.publicKey))
            try items.add(KeyRecord(key), keyData: Secret(copying: rawRepresentation), requiresUserPresence: true)
            return key
        }
    }

    /// Deletes the SSH key `id` for good: its private key is gone, and hosts that refer to it show it
    /// as not on this device. Deleting needs no unlock.
    /// - Throws: `KeychainError`.
    public func delete(id: SSHKey.ID) throws {
        try items.remove(id)
    }

    /// Signs `data` with the SSH key `keyID`, and returns the signature in SSH's wire format: what
    /// an SSH agent answers a sign request with (draft-ietf-sshm-ssh-agent section 4.5.1). An ECDSA
    /// key signs `data` hashed with SHA-256, as `ecdsa-sha2-nistp256` requires; `flags` matter only
    /// to RSA keys.
    ///
    /// A key that signs on every use asks the user first, giving `reason`, or a sentence that names
    /// the key; a key that signs while Shello is unlocked asks nobody.
    /// - Throws: `SSHKeyError.keyNotFound` for a key that is not on this device;
    ///   `UnlockWindowClosed` while app lock is engaged, for a key that signs while Shello is
    ///   unlocked; `UnlockError` if the user does not authenticate, for a key that signs on every
    ///   use; `KeychainError`, or what the Secure Enclave reported.
    @concurrent
    public func sign(
        _ data: Data, with keyID: SSHKey.ID, flags: SSHSignatureFlags = [], reason: String? = nil
    ) async throws -> Data {
        guard let key = try key(id: keyID) else { throw SSHKeyError.keyNotFound(keyID) }
        let items = items
        let enclave = enclave
        switch key.signingPolicy {
        case .whileUnlocked:
            return try unlockWindow.withAuthenticationContext { context in
                try Self.signature(for: data, by: key, items: items, enclave: enclave, context: context)
            }
        case .everyUse:
            let context = authentication.makeContext()
            defer { authentication.invalidate(context) }
            try await authentication.authenticate(
                context, reason: reason ?? "Sign in with the SSH key “\(key.comment)”.")
            // The signature takes the authentication just given, and asks nothing more.
            context.interactionNotAllowed = true
            return try Self.signature(for: data, by: key, items: items, enclave: enclave, context: context)
        }
    }

    private func newKey(
        _ kind: SSHKey.Kind, comment: String, signingPolicy: SigningPolicy, publicKey: SSHPublicKey
    ) -> SSHKey {
        SSHKey(
            id: UUID(), comment: comment, kind: kind, signingPolicy: signingPolicy, publicKey: publicKey,
            createdAt: Date())
    }

    /// Reads `key`'s key data with `context`, and signs `data` with it.
    private static func signature(
        for data: Data, by key: SSHKey, items: any KeyItems, enclave: any Enclave, context: LAContext
    ) throws -> Data {
        guard let keyData = try items.keyData(of: key.id, context: context) else {
            throw SSHKeyError.keyNotFound(key.id)
        }
        switch key.kind {
        case .secureEnclave:
            let blob = unsafe keyData.withUnsafeBytes { unsafe Data($0) }
            return SSHSignature.ecdsaP256(try enclave.signature(for: data, blob: blob, context: context))
        case .ed25519:
            let privateKey = try unsafe keyData.withUnsafeBytes { bytes in
                try unsafe Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
            }
            return SSHSignature.ed25519(try privateKey.signature(for: data))
        }
    }
}
