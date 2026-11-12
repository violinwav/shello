import Foundation
import Security
import Testing

@testable import ShelloSecurity

/// The items `SystemKeychain` asks the Keychain for. AppTests checks what the Keychain then stores,
/// inside the app, which has the Keychain entitlement.
struct SystemKeychainTests {
    let hostID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    @Test func itemIsAGenericPasswordFoundByKindAndOwner() {
        let query = SystemKeychain.query(for: .password(of: hostID))

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "ch.shello.password")
        #expect(query[kSecAttrAccount as String] as? String == "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
        #expect(
            SystemKeychain.query(for: .passphrase(of: hostID))[kSecAttrService as String] as? String
                == "ch.shello.passphrase")
    }

    /// Readable only on this device, only while it is unlocked, and never synced (README section 13).
    @Test func newItemIsDeviceOnlyAndNeverSynchronizable() {
        let item = SystemKeychain.newItem(.password(of: hostID), data: Data("hunter2".utf8))

        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(item[kSecValueData as String] as? Data == Data("hunter2".utf8))
        #expect(item[kSecAttrService as String] as? String == "ch.shello.password")
    }

    /// The Keychain puts new items into the app's first Keychain access group,
    /// `$(AppIdentifierPrefix)ch.shello.shared`, whose team prefix the code cannot know.
    @Test func queriesLeaveTheAccessGroupToTheEntitlement() {
        #expect(SystemKeychain.query(for: .password(of: hostID))[kSecAttrAccessGroup as String] == nil)
        #expect(SystemKeychain.newItem(.password(of: hostID), data: Data())[kSecAttrAccessGroup as String] == nil)
    }

    @Test func errorSaysWhatTheKeychainReported() {
        #expect(KeychainError(status: errSecItemNotFound).description.hasSuffix("(Keychain error -25300)"))
    }
}
