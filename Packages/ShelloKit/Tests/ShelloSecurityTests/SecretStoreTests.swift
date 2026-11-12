import Foundation
import Testing

@testable import ShelloSecurity

/// Passwords and passphrases in the Keychain, read inside the unlock window (README section 13).
/// The Keychain here is in memory: a test bundle has no Keychain entitlement. AppTests runs the
/// same operations on the iOS Keychain, inside the app.
struct SecretStoreTests {
    let authentication = TestAuthentication()
    let keychain = RecordingKeychain()
    let window: UnlockWindow
    let store: SecretStore

    let nas = UUID()
    let db = UUID()

    init() {
        window = UnlockWindow(authentication: authentication)
        store = SecretStore(keychain: keychain, unlockWindow: window)
    }

    @Test func secretRoundTrips() async throws {
        try await window.open(reason: "Unlock Shello")

        try store.store(Secret(utf8: "hunter2"), as: .password(of: nas))

        #expect(try store.secret(.password(of: nas))?.bytes == Array("hunter2".utf8))
        #expect(try store.contains(.password(of: nas)))
    }

    @Test func storingAgainReplacesTheSecret() async throws {
        try await window.open(reason: "Unlock Shello")
        try store.store(Secret(utf8: "hunter2"), as: .password(of: nas))

        try store.store(Secret(utf8: "correct horse"), as: .password(of: nas))

        #expect(try store.secret(.password(of: nas))?.bytes == Array("correct horse".utf8))
    }

    @Test func missingSecretIsNil() async throws {
        try await window.open(reason: "Unlock Shello")

        #expect(try store.secret(.password(of: nas)) == nil)
        #expect(try !store.contains(.password(of: nas)))
    }

    /// A host's password and an SSH key's passphrase are separate items, whoever owns them.
    @Test func kindsAndOwnersKeepTheirOwnSecrets() async throws {
        try await window.open(reason: "Unlock Shello")
        let owner = UUID()

        try store.store(Secret(utf8: "password"), as: .password(of: owner))
        try store.store(Secret(utf8: "passphrase"), as: .passphrase(of: owner))
        try store.store(Secret(utf8: "other password"), as: .password(of: db))

        #expect(try store.secret(.password(of: owner))?.bytes == Array("password".utf8))
        #expect(try store.secret(.passphrase(of: owner))?.bytes == Array("passphrase".utf8))
        #expect(try store.secret(.password(of: db))?.bytes == Array("other password".utf8))
    }

    @Test func removedSecretIsGone() async throws {
        try await window.open(reason: "Unlock Shello")
        try store.store(Secret(utf8: "hunter2"), as: .password(of: nas))

        try store.remove(.password(of: nas))

        #expect(try store.secret(.password(of: nas)) == nil)
    }

    /// A host's secrets go when the host goes, and nobody else's do.
    @Test func removingAHostsSecretsRemovesItsPasswordOnly() async throws {
        try await window.open(reason: "Unlock Shello")
        try store.store(Secret(utf8: "nas"), as: .password(of: nas))
        try store.store(Secret(utf8: "db"), as: .password(of: db))
        try store.store(Secret(utf8: "key"), as: .passphrase(of: nas))

        try store.removeSecrets(ofHost: nas)

        #expect(try store.secret(.password(of: nas)) == nil)
        #expect(try store.secret(.password(of: db)) != nil)
        #expect(try store.secret(.passphrase(of: nas)) != nil)
    }

    /// The acceptance criterion: once the user has unlocked, no Keychain read asks again. Every read
    /// gets the context the user authenticated on, and that context can no longer ask anything.
    @Test func readsInTheUnlockWindowDoNotAskAgain() async throws {
        try await window.open(reason: "Unlock Shello")
        try store.store(Secret(utf8: "nas"), as: .password(of: nas))
        try store.store(Secret(utf8: "db"), as: .password(of: db))

        for _ in 0..<3 {
            _ = try store.secret(.password(of: nas))
            _ = try store.secret(.password(of: db))
            _ = try store.contains(.password(of: nas))
        }

        #expect(authentication.promptCount == 1)
        let unlocked = authentication.promptedContexts[0]
        #expect(keychain.reads.count == 9)
        #expect(keychain.reads.allSatisfy { $0 == .init(context: unlocked, interactionNotAllowed: true) })
    }

    /// Once app lock re-engages, nothing is read until the user unlocks again, on a new context.
    @Test func readsWaitForTheNextUnlockOnceTheWindowCloses() async throws {
        try await window.open(reason: "Unlock Shello")
        try store.store(Secret(utf8: "hunter2"), as: .password(of: nas))
        window.close()

        #expect(throws: UnlockWindowClosed.self) { try store.secret(.password(of: nas)) }
        #expect(throws: UnlockWindowClosed.self) { try store.contains(.password(of: nas)) }
        #expect(throws: UnlockWindowClosed.self) { try store.store(Secret(utf8: "new"), as: .password(of: nas)) }
        #expect(keychain.reads.isEmpty)

        try await window.open(reason: "Unlock Shello")
        #expect(try store.secret(.password(of: nas))?.bytes == Array("hunter2".utf8))
        #expect(authentication.promptCount == 2)
        #expect(keychain.reads.map(\.context) == [authentication.promptedContexts[1]])
    }

    /// Deleting a host removes its secrets even while app lock is engaged, as a sync would.
    @Test func removingNeedsNoUnlock() async throws {
        try await window.open(reason: "Unlock Shello")
        try store.store(Secret(utf8: "hunter2"), as: .password(of: nas))
        window.close()

        try store.removeSecrets(ofHost: nas)

        try await window.open(reason: "Unlock Shello")
        #expect(try store.secret(.password(of: nas)) == nil)
    }
}
