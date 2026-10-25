import CryptoKit
import Foundation
import Security
import ShelloModel
import ShelloSecurity
import Testing

/// SSH keys in the iOS Keychain itself (README section 13, STACK section 7.3), from inside the app,
/// which is signed with Shello's Keychain access group. ShelloSecurityTests test the same logic on a
/// Keychain in memory and a stand-in for the Secure Enclave.
///
/// The simulator makes no Secure Enclave key that needs the user's presence, and its Keychain gives
/// out an item that needs the user's presence without asking. The tests that depend on either run
/// on a device only, and need a human to run them there.
struct SSHKeyKeychainTests {
    let window = UnlockWindow()
    let store: SSHKeyStore

    init() {
        window.openWithoutAuthentication()
        store = SSHKeyStore(unlockWindow: window)
    }

    /// Readable only on this device and only while it is unlocked, never synced (ADR 0003), in the
    /// shared access group, and the private key only with the user's presence.
    @Test func ed25519KeyIsADeviceOnlyItemThatNeedsTheUsersPresence() async throws {
        let key = try await store.generate(.ed25519, comment: "AppTests", signingPolicy: .whileUnlocked)
        defer { try? store.delete(id: key.id) }

        let attributes = try #require(try Self.attributes(of: key.id))

        #expect(attributes[kSecAttrAccessible as String] as? String == Self.deviceOnly)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecAttrAccessControl as String] != nil)
        let group = try #require(attributes[kSecAttrAccessGroup as String] as? String)
        #expect(group.hasSuffix(".ch.shello.shared"), "\(group)")
    }

    /// The Secure Enclave guards its key itself; its blob's item is device-only like any other.
    @Test(.enabled(if: SSHKeyStore(unlockWindow: UnlockWindow()).offersSecureEnclave))
    func secureEnclaveKeyIsADeviceOnlyItem() async throws {
        let key = try await store.generate(.secureEnclave, comment: "AppTests", signingPolicy: .whileUnlocked)
        defer { try? store.delete(id: key.id) }

        let attributes = try #require(try Self.attributes(of: key.id))

        #expect(attributes[kSecAttrAccessible as String] as? String == Self.deviceOnly)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(key.publicKey.algorithm == .ecdsaP256)
    }

    #if targetEnvironment(simulator)
        /// The record, which reads without authentication, does not hold the private key.
        @Test func recordInTheItemsAttributesHoldsNoPrivateKey() async throws {
            let key = try await store.generate(.ed25519, comment: "AppTests", signingPolicy: .whileUnlocked)
            defer { try? store.delete(id: key.id) }

            let attributes = try #require(try Self.attributes(of: key.id))
            let record = try #require(attributes[kSecAttrGeneric as String] as? Data)
            let privateKey = try #require(try Self.data(of: key.id))

            #expect(privateKey.count == 32)
            #expect(record.range(of: privateKey) == nil)
            #expect(!String(decoding: record, as: UTF8.self).contains(privateKey.base64EncodedString()))
        }

        /// As the app does it: a key made in the Keychain is listed, signs what its public key
        /// verifies, and goes when it is deleted.
        @Test func ed25519KeySignsAndGoesWhenDeleted() async throws {
            let key = try await store.generate(.ed25519, comment: "AppTests", signingPolicy: .whileUnlocked)
            defer { try? store.delete(id: key.id) }
            #expect(try store.keys().contains(key))
            let data = Data("session identifier".utf8)

            let signature = try await store.sign(data, with: key.id)

            // `ssh-ed25519` and the key or the signature, each the last field of its wire format.
            let publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: key.publicKey.wireRepresentation.suffix(32))
            #expect(publicKey.isValidSignature(signature.suffix(64), for: data))

            try store.delete(id: key.id)
            #expect(try !store.keys().contains(key))
            #expect(try Self.attributes(of: key.id) == nil)
        }
    #else
        /// On a device, the Keychain gives an Ed25519 private key only to a context on which the user
        /// authenticated: the unlock window here was opened without asking anyone.
        @Test func ed25519KeyDoesNotSignWithoutTheUsersPresence() async throws {
            let key = try await store.generate(.ed25519, comment: "AppTests", signingPolicy: .whileUnlocked)
            defer { try? store.delete(id: key.id) }

            await #expect(throws: (any Error).self) { try await store.sign(Data("data".utf8), with: key.id) }
        }

        /// On a device, the Secure Enclave signs only for a context on which the user authenticated.
        @Test(.enabled(if: SSHKeyStore(unlockWindow: UnlockWindow()).offersSecureEnclave))
        func secureEnclaveKeyDoesNotSignWithoutTheUsersPresence() async throws {
            let key = try await store.generate(.secureEnclave, comment: "AppTests", signingPolicy: .whileUnlocked)
            defer { try? store.delete(id: key.id) }

            await #expect(throws: (any Error).self) { try await store.sign(Data("data".utf8), with: key.id) }
        }
    #endif

    private static let deviceOnly = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    /// The attributes the Keychain keeps for the SSH key `id`, or nil if there is no such item.
    private static func attributes(of id: UUID) throws -> [String: Any]? {
        var query = query(for: id)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? [String: Any]
    }

    /// The data of the SSH key `id`'s item, which the simulator gives out without asking.
    private static func data(of id: UUID) throws -> Data? {
        var query = query(for: id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    private static func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ch.shello.ssh-key",
            kSecAttrAccount as String: id.uuidString,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }
}
