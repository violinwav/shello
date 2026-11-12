import CryptoKit
import Foundation
import Testing

@testable import ShelloSecurity

/// Generating SSH keys, and signing with them (README section 13, STACK section 7.3). The Keychain
/// is in memory and the Secure Enclave a stand-in, behind the same protocols as the device's: a test
/// bundle has no Keychain entitlement, and the iOS Simulator no Secure Enclave that makes keys with
/// access control. AppTests runs the Keychain's part inside the app.
struct SSHKeyStoreTests {
    let authentication = TestAuthentication()
    let items = RecordingKeyItems()
    let enclave = RecordingEnclave()
    let window: UnlockWindow
    let store: SSHKeyStore

    init() {
        window = UnlockWindow(authentication: authentication)
        store = SSHKeyStore(items: items, enclave: enclave, unlockWindow: window, authentication: authentication)
    }

    // MARK: - Generating

    @Test(arguments: SSHKey.Kind.generated)
    func generatedKeySignsWhatItsPublicKeyVerifies(kind: SSHKey.Kind) async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(kind, comment: "florian@iphone", signingPolicy: .whileUnlocked)
        let data = Data("session identifier".utf8)

        let signature = try await store.sign(data, with: key.id)

        #expect(try verify(signature, of: data, by: key))
        #expect(try !verify(signature, of: Data("something else".utf8), by: key))
    }

    @Test func secureEnclaveKeyIsECDSAP256AndEd25519KeyIsEd25519() async throws {
        try await window.open(reason: "Unlock Shello")

        let secureEnclave = try await store.generate(.secureEnclave, comment: "a", signingPolicy: .whileUnlocked)
        let ed25519 = try await store.generate(.ed25519, comment: "b", signingPolicy: .whileUnlocked)

        #expect(secureEnclave.publicKey.algorithm == .ecdsaP256)
        #expect(secureEnclave.openSSHPublicKey.hasPrefix("ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY"))
        #expect(secureEnclave.openSSHPublicKey.hasSuffix(" a"))
        #expect(ed25519.publicKey.algorithm == .ed25519)
        #expect(ed25519.openSSHPublicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        #expect(ed25519.publicKey.fingerprint.hasPrefix("SHA256:"))
    }

    @Test func keysAreListedByNameWithTheirKindAndSigningPolicy() async throws {
        try await window.open(reason: "Unlock Shello")
        let work = try await store.generate(.secureEnclave, comment: "work", signingPolicy: .everyUse)
        let homelab = try await store.generate(.ed25519, comment: "Homelab", signingPolicy: .whileUnlocked)
        let key10 = try await store.generate(.ed25519, comment: "key 10", signingPolicy: .whileUnlocked)
        let key9 = try await store.generate(.ed25519, comment: "key 9", signingPolicy: .whileUnlocked)

        let keys = try store.keys()

        #expect(keys == [homelab, key9, key10, work])
        #expect(keys.last?.kind == .secureEnclave)
        #expect(keys.last?.signingPolicy == .everyUse)
        #expect(try store.key(id: work.id) == work)
        #expect(try store.key(id: UUID()) == nil)
    }

    @Test func nameLosesSurroundingWhitespaceAndCannotHoldALineBreak() async throws {
        try await window.open(reason: "Unlock Shello")

        let key = try await store.generate(.ed25519, comment: "  deploy@ci \n", signingPolicy: .whileUnlocked)
        #expect(key.comment == "deploy@ci")

        await #expect(throws: SSHKeyError.invalidComment) {
            try await store.generate(.ed25519, comment: "two\nlines", signingPolicy: .whileUnlocked)
        }
        await #expect(throws: SSHKeyError.invalidComment) {
            try await store.generate(.ed25519, comment: "tab\tinside", signingPolicy: .whileUnlocked)
        }
        #expect(try store.keys().map(\.comment) == ["deploy@ci"])
    }

    /// The iOS Simulator has no Secure Enclave that makes keys with access control.
    @Test func withoutASecureEnclaveOnlyEd25519IsOffered() async throws {
        let store = SSHKeyStore(
            items: items, enclave: RecordingEnclave(isAvailable: false), unlockWindow: window,
            authentication: authentication)
        try await window.open(reason: "Unlock Shello")

        #expect(!store.offersSecureEnclave)
        #expect(store.kinds == [.ed25519])
        await #expect(throws: SSHKeyError.secureEnclaveUnavailable) {
            try await store.generate(.secureEnclave, comment: "a", signingPolicy: .whileUnlocked)
        }
        #expect(try store.keys().isEmpty)
        #expect(self.store.kinds == [.secureEnclave, .ed25519])
    }

    @Test func generatingWaitsForTheUnlockWindow() async throws {
        await #expect(throws: UnlockWindowClosed.self) {
            try await store.generate(.ed25519, comment: "a", signingPolicy: .whileUnlocked)
        }
        #expect(try store.keys().isEmpty)
    }

    // MARK: - Deleting

    @Test func deletedKeyIsGoneAndNoLongerSigns() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.secureEnclave, comment: "a", signingPolicy: .whileUnlocked)
        let other = try await store.generate(.ed25519, comment: "b", signingPolicy: .whileUnlocked)
        window.close()

        // As removing a secret does, deleting needs no unlock.
        try store.delete(id: key.id)

        try await window.open(reason: "Unlock Shello")
        #expect(try store.keys() == [other])
        await #expect(throws: SSHKeyError.keyNotFound(key.id)) { try await store.sign(Data(), with: key.id) }
    }

    @Test func keyThatIsNotOnThisDeviceDoesNotSign() async throws {
        try await window.open(reason: "Unlock Shello")
        let id = UUID()

        await #expect(throws: SSHKeyError.keyNotFound(id)) { try await store.sign(Data(), with: id) }
    }

    // MARK: - Signing policies

    /// "While Shello is unlocked": the user authenticated once, at app lock, and every signature
    /// takes that context, which can ask nothing more.
    @Test(arguments: SSHKey.Kind.generated)
    func keyThatSignsWhileUnlockedUsesTheUnlockWindowAndAsksNoMore(kind: SSHKey.Kind) async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(kind, comment: "a", signingPolicy: .whileUnlocked)

        for _ in 0..<3 {
            _ = try await store.sign(Data("data".utf8), with: key.id)
        }

        #expect(authentication.promptCount == 1)
        let unlocked = RecordingKeychain.Read(context: authentication.promptedContexts[0], interactionNotAllowed: true)
        #expect(contextsThatSigned(kind) == Array(repeating: unlocked, count: 3))
    }

    @Test(arguments: SSHKey.Kind.generated)
    func keyThatSignsWhileUnlockedWaitsForTheNextUnlock(kind: SSHKey.Kind) async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(kind, comment: "a", signingPolicy: .whileUnlocked)
        window.close()

        await #expect(throws: UnlockWindowClosed.self) { try await store.sign(Data(), with: key.id) }

        #expect(items.reads.isEmpty)
        #expect(enclave.signatures.isEmpty)
        #expect(authentication.promptCount == 1)
    }

    /// "Every use": each signature asks the user, on a context of its own, which signs that one
    /// signature, and is invalidated after it. The unlock window's context is never used.
    @Test(arguments: SSHKey.Kind.generated)
    func keyThatSignsOnEveryUseAsksForEachSignature(kind: SSHKey.Kind) async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(kind, comment: "work", signingPolicy: .everyUse)
        let data = Data("data".utf8)

        for _ in 0..<3 {
            #expect(try verify(try await store.sign(data, with: key.id), of: data, by: key))
        }

        #expect(authentication.promptCount == 4)
        let prompted = Array(authentication.promptedContexts.dropFirst())
        #expect(Set(prompted).count == 3)
        #expect(!prompted.contains(authentication.promptedContexts[0]))
        #expect(prompted.allSatisfy(authentication.isInvalidated))
        let expected = prompted.map { RecordingKeychain.Read(context: $0, interactionNotAllowed: true) }
        #expect(contextsThatSigned(kind) == expected)
        #expect(authentication.reasons.dropFirst().allSatisfy { $0 == "Sign in with the SSH key “work”." })
    }

    @Test func keyThatSignsOnEveryUseShowsTheReasonItIsGiven() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.ed25519, comment: "work", signingPolicy: .everyUse)

        _ = try await store.sign(Data(), with: key.id, reason: "Sign in to prod-api-02.")

        #expect(authentication.reasons.last == "Sign in to prod-api-02.")
    }

    @Test(arguments: [UnlockError.cancelled, .failed])
    func keyThatSignsOnEveryUseDoesNotSignWithoutTheUser(error: UnlockError) async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.ed25519, comment: "a", signingPolicy: .everyUse)
        authentication.answer(.failure(error))

        await #expect(throws: error) { try await store.sign(Data(), with: key.id) }

        #expect(items.reads.isEmpty)
        #expect(authentication.isInvalidated(authentication.promptedContexts[1]))
    }

    /// A key that asks on every use needs nothing else: its own prompt is at least as strong as the
    /// unlock window's.
    @Test func keyThatSignsOnEveryUseSignsWhileTheWindowIsClosed() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.secureEnclave, comment: "a", signingPolicy: .everyUse)
        window.close()

        let signature = try await store.sign(Data("data".utf8), with: key.id)

        #expect(try verify(signature, of: Data("data".utf8), by: key))
        #expect(authentication.promptCount == 2)
    }

    /// The flags choose an RSA key's hash: the signatures of ECDSA and Ed25519 keys stay as they are.
    @Test(arguments: SSHKey.Kind.generated)
    func flagsChangeNothingForECDSAAndEd25519(kind: SSHKey.Kind) async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(kind, comment: "a", signingPolicy: .whileUnlocked)
        let data = Data("data".utf8)

        let signature = try await store.sign(data, with: key.id, flags: [.rsaSHA256, .rsaSHA512])

        #expect(try ParsedSSHSignature(signature).algorithm == kind.algorithm.name)
        #expect(try verify(signature, of: data, by: key))
    }

    // MARK: - Against ssh-keygen

    /// The store's signature with RFC 6979's key verifies against the public key `ssh-keygen`
    /// printed for it: the signature OpenSSH would check on a server.
    @Test func secureEnclaveKeySignsForTheKeySSHKeygenDescribes() async throws {
        try await window.open(reason: "Unlock Shello")
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: SSHKeygenVectors.ECDSA.privateKey)
        let key = try addKey(
            .secureEnclave, publicKey: SSHPublicKey(privateKey.publicKey),
            keyData: enclave.enclave.insert(privateKey))

        let signature = try await store.sign(SSHKeygenVectors.signedData, with: key.id)

        #expect(key.openSSHPublicKey == SSHKeygenVectors.ECDSA.publicKey)
        let publicKey = try ParsedOpenSSHLine(SSHKeygenVectors.ECDSA.publicKey).p256PublicKey()
        let parsed = try ParsedSSHSignature(signature)
        #expect(parsed.algorithm == "ecdsa-sha2-nistp256")
        #expect(publicKey.isValidSignature(try parsed.ecdsaSignature(), for: SSHKeygenVectors.signedData))
    }

    @Test func ed25519KeySignsForTheKeySSHKeygenDescribes() async throws {
        try await window.open(reason: "Unlock Shello")
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: SSHKeygenVectors.Ed25519.privateKey)
        let key = try addKey(
            .ed25519, publicKey: SSHPublicKey(privateKey.publicKey), keyData: SSHKeygenVectors.Ed25519.privateKey)

        let signature = try await store.sign(SSHKeygenVectors.signedData, with: key.id)

        #expect(key.openSSHPublicKey == SSHKeygenVectors.Ed25519.publicKey)
        let publicKey = try ParsedOpenSSHLine(SSHKeygenVectors.Ed25519.publicKey).ed25519PublicKey()
        let parsed = try ParsedSSHSignature(signature)
        #expect(parsed.algorithm == "ssh-ed25519")
        #expect(publicKey.isValidSignature(parsed.blob, for: SSHKeygenVectors.signedData))
    }

    // MARK: - Private keys stay inside

    /// What the store hands out is public: an `SSHKey` holds no more than these fields, and shows
    /// none of the private key's bytes when printed or dumped.
    @Test(arguments: SSHKey.Kind.generated)
    func keyHoldsNoPrivateKeyMaterial(kind: SSHKey.Kind) async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(kind, comment: "a", signingPolicy: .whileUnlocked)
        let keyData = try #require(items.items.keyData(of: key.id, context: .init()))

        let fields = Mirror(reflecting: key).children.map(\.label)
        #expect(fields == ["id", "comment", "kind", "signingPolicy", "publicKey", "createdAt"])
        var dumped = ""
        dump(key, to: &dumped)
        for text in [dumped, String(describing: key), String(reflecting: key), key.openSSHPublicKey] {
            #expect(!contains(text, keyData))
        }
    }

    /// The record lies in the Keychain item's attributes, which read without authentication: it
    /// must not hold the private key, which only an authenticated context reads.
    @Test(arguments: SSHKey.Kind.generated)
    func recordInTheKeychainHoldsNoPrivateKey(kind: SSHKey.Kind) async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(kind, comment: "a", signingPolicy: .whileUnlocked)
        let keyData = try #require(items.items.keyData(of: key.id, context: .init()))

        let attributes = try SystemKeyItems.encoder.encode(KeyRecord(key))

        #expect(!contains(String(decoding: attributes, as: UTF8.self), keyData))
        #expect(attributes.range(of: unsafe keyData.withUnsafeBytes { unsafe Data($0) }) == nil)
    }

    /// An Ed25519 private key reads only with the user's presence. A Secure Enclave key's blob needs
    /// none: the Secure Enclave asks for the user's presence itself, and the blob is useless
    /// anywhere else.
    @Test func ed25519PrivateKeyNeedsTheUsersPresenceToRead() async throws {
        try await window.open(reason: "Unlock Shello")
        let ed25519 = try await store.generate(.ed25519, comment: "a", signingPolicy: .whileUnlocked)
        let secureEnclave = try await store.generate(.secureEnclave, comment: "b", signingPolicy: .whileUnlocked)

        #expect(items.items.requiresUserPresence(ed25519.id) == true)
        #expect(items.items.requiresUserPresence(secureEnclave.id) == false)
    }

    /// A record this version does not understand, as a newer Shello may write, is left out.
    @Test func recordOfAnUnknownKindIsLeftOut() async throws {
        try await window.open(reason: "Unlock Shello")
        let known = try await store.generate(.ed25519, comment: "a", signingPolicy: .whileUnlocked)
        var unknown = KeyRecord(known)
        unknown.id = UUID()
        unknown.kind = "rsa"
        try items.add(unknown, keyData: Secret(copying: [1, 2, 3]), requiresUserPresence: true)

        #expect(try store.keys() == [known])
        await #expect(throws: SSHKeyError.keyNotFound(unknown.id)) { try await store.sign(Data(), with: unknown.id) }
    }

    // MARK: - Fixtures

    /// A fixture key has the same identifier in every store in memory, as at every launch of a UI
    /// test, so that a host saved with it finds it after the app was terminated and launched again;
    /// two fixtures have two.
    @Test func fixtureKeyKeepsItsIdentifierFromStoreToStore() throws {
        let fixtures = [
            SSHKeyStore.FixtureKey(privateKey: Data(repeating: 7, count: 32), comment: "first"),
            SSHKeyStore.FixtureKey(privateKey: Data(repeating: 8, count: 32), comment: "second"),
        ]

        let one = SSHKeyStore.inMemory(unlockWindow: window, authentication: authentication, fixtureKeys: fixtures)
        let other = SSHKeyStore.inMemory(unlockWindow: window, authentication: authentication, fixtureKeys: fixtures)

        #expect(try one.keys().map(\.id) == other.keys().map(\.id))
        #expect(Set(try one.keys().map(\.id)).count == 2)
    }

    // MARK: - Helpers

    /// Whether `signature`, in SSH's wire format, is `key`'s signature of `data`, checked as a server
    /// would: with the public key as SSH sends it.
    private func verify(_ signature: Data, of data: Data, by key: SSHKey) throws -> Bool {
        let line = try ParsedOpenSSHLine(key.openSSHPublicKey)
        let parsed = try ParsedSSHSignature(signature)
        guard parsed.isMade(by: line) else { return false }
        switch key.kind {
        case .secureEnclave, .imported(.ecdsaP256):
            return try line.p256PublicKey().isValidSignature(try parsed.ecdsaSignature(), for: data)
        case .ed25519, .imported(.ed25519):
            return try line.ed25519PublicKey().isValidSignature(parsed.blob, for: data)
        case .imported(.ecdsaP384):
            return try line.p384PublicKey().isValidSignature(try parsed.p384Signature(), for: data)
        case .imported(.rsa):
            return try parsed.isValidRSASignature(for: data, by: try line.rsaPublicKey())
        }
    }

    /// The contexts the key data of `kind` was used with: read for Ed25519, signed with in the
    /// Secure Enclave.
    private func contextsThatSigned(_ kind: SSHKey.Kind) -> [RecordingKeychain.Read] {
        switch kind {
        case .secureEnclave: enclave.signatures
        case .ed25519, .imported: items.reads
        }
    }

    /// Stores a key with this public key and key data, as `generate` would.
    private func addKey(_ kind: SSHKey.Kind, publicKey: SSHPublicKey, keyData: Data) throws -> SSHKey {
        let comment =
            kind == .ed25519 ? SSHKeygenVectors.Ed25519.comment : SSHKeygenVectors.ECDSA.comment
        let key = SSHKey(
            id: UUID(), comment: comment, kind: kind, signingPolicy: .whileUnlocked, publicKey: publicKey,
            createdAt: Date())
        try items.add(KeyRecord(key), keyData: Secret(copying: keyData), requiresUserPresence: kind == .ed25519)
        return key
    }

    /// Whether `text` holds the bytes of `secret` in hex or in base64.
    private func contains(_ text: String, _ secret: Secret) -> Bool {
        let bytes = unsafe secret.withUnsafeBytes { unsafe Data($0) }
        let hex = bytes.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
        return text.localizedCaseInsensitiveContains(hex) || text.contains(bytes.base64EncodedString())
    }
}
