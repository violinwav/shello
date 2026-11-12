import Foundation
import LocalAuthentication
import Security
import ShelloSecurity
import Testing

/// The iOS Keychain itself (README section 13, STACK section 7.3), from inside the app, which is
/// signed with Shello's Keychain access group. ShelloSecurityTests test the same logic on a Keychain
/// in memory, because a test bundle of its own has no Keychain entitlement.
struct KeychainTests {
    let keychain = SystemKeychain()

    @Test func secretRoundTrips() throws {
        let id = SecretID.password(of: UUID())
        defer { try? keychain.remove(id) }

        try keychain.store(Secret(utf8: "hunter2"), as: id)

        #expect(try keychain.secret(id, context: LAContext()).map(bytes) == Array("hunter2".utf8))
        #expect(try keychain.contains(id, context: LAContext()))
    }

    @Test func storingAgainReplacesTheSecret() throws {
        let id = SecretID.password(of: UUID())
        defer { try? keychain.remove(id) }
        try keychain.store(Secret(utf8: "hunter2"), as: id)

        try keychain.store(Secret(utf8: "correct horse battery staple"), as: id)

        #expect(try keychain.secret(id, context: LAContext()).map(bytes) == Array("correct horse battery staple".utf8))
    }

    /// Readable only on this device and only while it is unlocked, never synced, and shared with
    /// Shello's extensions through the access group `$(AppIdentifierPrefix)ch.shello.shared`.
    @Test func itemIsDeviceOnlyNeverSyncsAndIsInTheSharedAccessGroup() throws {
        let id = SecretID.password(of: UUID())
        defer { try? keychain.remove(id) }
        try keychain.store(Secret(utf8: "hunter2"), as: id)

        let attributes = try #require(try Self.attributes(of: id))

        let accessible = attributes[kSecAttrAccessible as String] as? String
        #expect(accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        let group = try #require(attributes[kSecAttrAccessGroup as String] as? String)
        #expect(group.hasSuffix(".ch.shello.shared"), "\(group)")
    }

    @Test func removedSecretIsGone() throws {
        let id = SecretID.password(of: UUID())
        try keychain.store(Secret(utf8: "hunter2"), as: id)

        try keychain.remove(id)

        #expect(try keychain.secret(id, context: LAContext()) == nil)
        #expect(try !keychain.contains(id, context: LAContext()))
        #expect(try Self.attributes(of: id) == nil)
    }

    @Test func removingASecretThatIsNotThereSucceeds() throws {
        try keychain.remove(.password(of: UUID()))
    }

    /// As the app does it: inside an open unlock window, the store keeps a host's password, and
    /// removes it with the host.
    @Test func storeKeepsAHostsPasswordUntilTheHostGoes() throws {
        let window = UnlockWindow()
        window.openWithoutAuthentication()
        let store = SecretStore(keychain: keychain, unlockWindow: window)
        let host = UUID()
        let other = UUID()
        defer {
            try? store.removeSecrets(ofHost: host)
            try? store.removeSecrets(ofHost: other)
        }
        try store.store(Secret(utf8: "hunter2"), as: .password(of: host))
        try store.store(Secret(utf8: "other"), as: .password(of: other))

        try store.removeSecrets(ofHost: host)

        #expect(try store.secret(.password(of: host)) == nil)
        #expect(try store.secret(.password(of: other)).map(bytes) == Array("other".utf8))
    }

    private func bytes(_ secret: Secret) -> [UInt8] {
        secret.withUnsafeBytes { Array($0) }
    }

    /// The attributes the Keychain keeps for the item `id`, or nil if there is no such item.
    private static func attributes(of id: SecretID) throws -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: id.kind == .password ? "ch.shello.password" : "ch.shello.passphrase",
            kSecAttrAccount as String: id.owner.uuidString,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? [String: Any]
    }
}
