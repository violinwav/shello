import CryptoKit
import Foundation
import LocalAuthentication
import ShelloModel

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
/// It also keeps imported keys, which the user brought from elsewhere: Ed25519, ECDSA P-256 and
/// P-384, and RSA, which signs with SHA-256 or SHA-512 only. Their private key is a Keychain item
/// like an Ed25519 key's, and their passphrase is not kept.
///
/// Every item is `WhenUnlockedThisDeviceOnly` and never synchronizable, so it is in no backup that
/// leaves the device, and never syncs; syncing imported keys is for v1, when the user opts in. The
/// store hands out no private key: it returns `SSHKey`s, which hold public data only, and
/// signatures.
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
    /// `fixtureKeys` are there from the start, so that a test can sign in to a test server that
    /// knows them; one that is not an Ed25519 private key is left out. Each has the same identifier
    /// in every store, made from its public key, so that a host saved with it in one launch of a UI
    /// test finds it in the next.
    public static func inMemory(
        unlockWindow: UnlockWindow, authentication: some Authentication = LocalAuthentication(),
        secureEnclave: Bool = false, fixtureKeys: [FixtureKey] = []
    ) -> SSHKeyStore {
        let items = MemoryKeyItems()
        for fixture in fixtureKeys {
            guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: fixture.privateKey) else {
                continue
            }
            let key = SSHKey(
                id: fixtureIdentifier(of: privateKey.publicKey), comment: fixture.comment, kind: .ed25519,
                signingPolicy: fixture.signingPolicy, publicKey: SSHPublicKey(privateKey.publicKey), createdAt: Date())
            try? items.add(KeyRecord(key), keyData: Secret(copying: fixture.privateKey), requiresUserPresence: true)
        }
        return SSHKeyStore(
            items: items, enclave: MemoryEnclave(isAvailable: secureEnclave), unlockWindow: unlockWindow,
            authentication: authentication)
    }

    /// The identifier of the fixture key whose public key is `publicKey`: the first 16 bytes of the
    /// key's SHA-256 hash, as a UUID of version 8, which RFC 9562 leaves to the application.
    private static func fixtureIdentifier(of publicKey: Curve25519.Signing.PublicKey) -> UUID {
        var bytes = Array(SHA256.hash(data: publicKey.rawRepresentation).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x80
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// An Ed25519 key that a store in memory starts with (`inMemory(…)`): a test fixture whose
    /// public key a test server lets in, such as TestServers/keys/client_ed25519.
    public struct FixtureKey: Sendable {
        /// The private key's 32 bytes (`Curve25519.Signing.PrivateKey.rawRepresentation`).
        public let privateKey: Data
        public let comment: String
        public let signingPolicy: SigningPolicy

        public init(privateKey: Data, comment: String, signingPolicy: SigningPolicy = .standard) {
            self.privateKey = privateKey
            self.comment = comment
            self.signingPolicy = signingPolicy
        }
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

    /// The SSH key `id`, if it could sign now: it is on this device, and it signs on every use, or
    /// Shello is unlocked. A connection checks this before it goes over the network.
    /// - Throws: `SSHKeyError.keyNotFound` for a key that is not on this device; `UnlockWindowClosed`
    ///   while app lock is engaged, for a key that signs while Shello is unlocked; `KeychainError`.
    public func signingKey(id: SSHKey.ID) throws -> SSHKey {
        guard let key = try key(id: id) else { throw SSHKeyError.keyNotFound(id) }
        if key.signingPolicy == .whileUnlocked, !unlockWindow.isOpen {
            throw UnlockWindowClosed()
        }
        return key
    }

    /// Makes a new SSH key of `kind`, named `comment`, that signs as `signingPolicy` says.
    /// Surrounding whitespace is left out of the name.
    /// - Throws: `UnlockWindowClosed` while app lock is engaged; `SSHKeyError.invalidComment` for a
    ///   name with a line break, `.secureEnclaveUnavailable` for a Secure Enclave key on a device
    ///   that cannot make one, `.cannotMake` for an imported key; `KeychainError`, or what the Secure
    ///   Enclave reported.
    @concurrent
    public func generate(_ kind: SSHKey.Kind, comment: String, signingPolicy: SigningPolicy) async throws -> SSHKey {
        guard unlockWindow.isOpen else { throw UnlockWindowClosed() }
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHKey.isValidComment(comment) else { throw SSHKeyError.invalidComment }
        switch kind {
        case .imported:
            throw SSHKeyError.cannotMake(kind)
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

    /// Keeps the imported key `material` (README section 13), which ShelloSSH read from the user's
    /// file or paste, named `comment`, signing as `signingPolicy` says. Surrounding whitespace is
    /// left out of the name. Its private key goes into the Keychain as an Ed25519 key's does: on this
    /// device only, never synchronizable, readable only with the user's presence. The material's
    /// buffer is the caller's, which overwrites it once it lets it go.
    ///
    /// Shello computes the public key from the private key, as it writes the public keys of the keys
    /// it makes, and imports only a key whose public key is the one libssh read.
    /// - Throws: `UnlockWindowClosed` while app lock is engaged; `SSHKeyError.invalidComment` for a
    ///   name with a line break, `.mismatchedKeyPair` for a private key that is not the public key's,
    ///   or that Apple's frameworks cannot use; `KeychainError`.
    @concurrent
    public func importKey(
        _ material: ImportedKeyMaterial, comment: String, signingPolicy: SigningPolicy
    ) async throws -> SSHKey {
        guard unlockWindow.isOpen else { throw UnlockWindowClosed() }
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHKey.isValidComment(comment) else { throw SSHKeyError.invalidComment }
        let algorithm = material.algorithm
        let publicKey = try unsafe material.privateKey.withUnsafeBytes { bytes in
            try unsafe Self.publicKey(of: algorithm, privateKey: bytes)
        }
        guard publicKey.wireRepresentation.elementsEqual(material.publicKey) else {
            throw SSHKeyError.mismatchedKeyPair
        }
        let key = newKey(.imported(algorithm), comment: comment, signingPolicy: signingPolicy, publicKey: publicKey)
        let keyData = unsafe material.privateKey.withUnsafeBytes { unsafe Secret(copying: $0) }
        try items.add(KeyRecord(key), keyData: keyData, requiresUserPresence: true)
        return key
    }

    /// Deletes the SSH key `id` for good: its private key is gone, and hosts that refer to it show it
    /// as not on this device. Deleting needs no unlock.
    /// - Throws: `KeychainError`.
    public func delete(id: SSHKey.ID) throws {
        try items.remove(id)
    }

    /// Signs `data` with the SSH key `keyID`, and returns the signature in SSH's wire format: what
    /// an SSH agent answers a sign request with (draft-ietf-sshm-ssh-agent section 4.5.1). An ECDSA
    /// key signs `data` hashed with its curve's hash, SHA-256 for `ecdsa-sha2-nistp256` and SHA-384
    /// for `ecdsa-sha2-nistp384`. `flags` matter only to RSA keys, which sign with SHA-256 or SHA-512
    /// as they say (RFC 8332), and never with SHA-1.
    ///
    /// A key that signs on every use asks the user first, giving `reason`, or a sentence that names
    /// the key; a key that signs while Shello is unlocked asks nobody. Cancelling the task ends the
    /// prompt, as when the SSH agent closes for a tab that closes.
    /// - Throws: `SSHKeyError.keyNotFound` for a key that is not on this device, `.rsaSHA1Refused` for
    ///   an RSA key asked for neither SHA-256 nor SHA-512; `UnlockWindowClosed` while app lock is
    ///   engaged, for a key that signs while Shello is unlocked; `UnlockError` if the user does not
    ///   authenticate, for a key that signs on every use; `KeychainError`, or what the Secure Enclave
    ///   or Security reported.
    @concurrent
    public func sign(
        _ data: Data, with keyID: SSHKey.ID, flags: SSHSignatureFlags = [], reason: String? = nil
    ) async throws -> Data {
        guard let key = try key(id: keyID) else { throw SSHKeyError.keyNotFound(keyID) }
        // Before anyone is asked: an RSA key never signs with SHA-1.
        if key.kind.algorithm == .rsa, RSAHash(flags) == nil {
            throw SSHKeyError.rsaSHA1Refused
        }
        let items = items
        let enclave = enclave
        switch key.signingPolicy {
        case .whileUnlocked:
            return try unlockWindow.withAuthenticationContext { context in
                try Self.signature(for: data, by: key, flags: flags, items: items, enclave: enclave, context: context)
            }
        case .everyUse:
            let context = authentication.makeContext()
            defer { authentication.invalidate(context) }
            let authentication = authentication
            let prompt = PromptContext(context)
            try await withTaskCancellationHandler {
                try await authentication.authenticate(
                    context, reason: reason ?? "Sign in with the SSH key “\(key.comment)”.")
            } onCancel: {
                authentication.invalidate(prompt.context)
            }
            // The signature takes the authentication just given, and asks nothing more.
            context.interactionNotAllowed = true
            return try Self.signature(
                for: data, by: key, flags: flags, items: items, enclave: enclave, context: context)
        }
    }

    private func newKey(
        _ kind: SSHKey.Kind, comment: String, signingPolicy: SigningPolicy, publicKey: SSHPublicKey
    ) -> SSHKey {
        SSHKey(
            id: UUID(), comment: comment, kind: kind, signingPolicy: signingPolicy, publicKey: publicKey,
            createdAt: Date())
    }

    /// Reads `key`'s key data with `context`, and signs `data` with it, as `flags` ask of an RSA key.
    private static func signature(
        for data: Data, by key: SSHKey, flags: SSHSignatureFlags, items: any KeyItems, enclave: any Enclave,
        context: LAContext
    ) throws -> Data {
        guard let keyData = try items.keyData(of: key.id, context: context) else {
            throw SSHKeyError.keyNotFound(key.id)
        }
        switch key.kind {
        case .secureEnclave:
            let blob = unsafe keyData.withUnsafeBytes { unsafe Data($0) }
            return SSHSignature.ecdsaP256(try enclave.signature(for: data, blob: blob, context: context))
        case .ed25519, .imported(.ed25519):
            let privateKey = try unsafe keyData.withUnsafeBytes { bytes in
                try unsafe Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
            }
            return SSHSignature.ed25519(try privateKey.signature(for: data))
        case .imported(.ecdsaP256):
            let privateKey = try unsafe keyData.withUnsafeBytes { bytes in
                try unsafe P256.Signing.PrivateKey(rawRepresentation: bytes)
            }
            return SSHSignature.ecdsaP256(try privateKey.signature(for: data))
        case .imported(.ecdsaP384):
            let privateKey = try unsafe keyData.withUnsafeBytes { bytes in
                try unsafe P384.Signing.PrivateKey(rawRepresentation: bytes)
            }
            return SSHSignature.ecdsaP384(try privateKey.signature(for: data))
        case .imported(.rsa):
            guard let hash = RSAHash(flags) else { throw SSHKeyError.rsaSHA1Refused }
            let privateKey = try unsafe keyData.withUnsafeBytes { bytes in try unsafe RSAKey.privateKey(der: bytes) }
            return try RSAKey.signature(for: data, by: privateKey, hash: hash)
        }
    }

    /// The public key of the imported private key `privateKey` of `algorithm`, in the form
    /// `ImportedKeyMaterial` describes, as Shello writes it.
    /// - Throws: `SSHKeyError.mismatchedKeyPair` for a private key Apple's frameworks cannot read.
    private static func publicKey(
        of algorithm: SSHKeyAlgorithm, privateKey: UnsafeRawBufferPointer
    ) throws(SSHKeyError) -> SSHPublicKey {
        do {
            switch algorithm {
            case .ed25519:
                return SSHPublicKey(try unsafe Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).publicKey)
            case .ecdsaP256:
                return SSHPublicKey(try unsafe P256.Signing.PrivateKey(rawRepresentation: privateKey).publicKey)
            case .ecdsaP384:
                return SSHPublicKey(try unsafe P384.Signing.PrivateKey(rawRepresentation: privateKey).publicKey)
            case .rsa:
                return try RSAKey.publicKey(of: try unsafe RSAKey.privateKey(der: privateKey))
            }
        } catch {
            throw .mismatchedKeyPair
        }
    }
}

/// The context a signature asks the user on, which is not sendable, in a box that the task's
/// cancellation handler can reach: it only invalidates the context, which LocalAuthentication allows
/// from any thread, and which ends the prompt.
private final class PromptContext: @unchecked Sendable {
    let context: LAContext

    init(_ context: LAContext) {
        self.context = context
    }
}
