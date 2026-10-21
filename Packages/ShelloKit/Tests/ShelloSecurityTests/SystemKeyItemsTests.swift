import CryptoKit
import Foundation
import Security
import Testing

@testable import ShelloSecurity

/// The items `SystemKeyItems` asks the Keychain for. AppTests checks what the Keychain then stores,
/// inside the app, which has the Keychain entitlement.
struct SystemKeyItemsTests {
    let key = SSHKey(
        id: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!, comment: "florian@iphone", kind: .ed25519,
        signingPolicy: .everyUse,
        publicKey: SSHPublicKey(Curve25519.Signing.PrivateKey().publicKey),
        createdAt: Date(timeIntervalSinceReferenceDate: 814_000_000.5))

    @Test func itemIsAGenericPasswordFoundByTheKeysIdentifier() {
        let query = SystemKeyItems.query(for: key.id)

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "ch.shello.ssh-key")
        #expect(query[kSecAttrAccount as String] as? String == "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
    }

    /// Readable only on this device, only while it is unlocked, never synced (ADR 0003), and the
    /// data only with the user's presence.
    @Test func ed25519ItemIsDeviceOnlyNeverSynchronizableAndNeedsTheUsersPresence() throws {
        let accessControl = try deviceOnlyAccessControl(.userPresence)

        let item = SystemKeyItems.newItem(
            key.id, attributes: Data("{}".utf8), data: Data([1, 2, 3]), accessControl: accessControl)

        // The access control carries the protection class; an item cannot have both.
        #expect(item[kSecAttrAccessControl as String] != nil)
        #expect(item[kSecAttrAccessible as String] == nil)
        #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(item[kSecValueData as String] as? Data == Data([1, 2, 3]))
        #expect(item[kSecAttrGeneric as String] as? Data == Data("{}".utf8))
    }

    @Test func secureEnclaveItemIsDeviceOnlyAndNeverSynchronizable() {
        let item = SystemKeyItems.newItem(key.id, attributes: Data(), data: Data([1]), accessControl: nil)

        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(item[kSecAttrAccessControl as String] == nil)
        #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test func queriesLeaveTheAccessGroupToTheEntitlement() {
        #expect(SystemKeyItems.query(for: key.id)[kSecAttrAccessGroup as String] == nil)
        #expect(SystemKeyItems.allItems[kSecAttrAccessGroup as String] == nil)
        let item = SystemKeyItems.newItem(key.id, attributes: Data(), data: Data(), accessControl: nil)
        #expect(item[kSecAttrAccessGroup as String] == nil)
    }

    @Test func recordRoundTripsThroughTheItemsAttributes() throws {
        let attributes: [String: Any] = [
            kSecAttrAccount as String: key.id.uuidString,
            kSecAttrGeneric as String: try SystemKeyItems.encoder.encode(KeyRecord(key)),
        ]

        let record = try #require(SystemKeyItems.record(in: attributes))

        #expect(record.key == key)
        #expect(record.version == 1)
    }

    /// The record's format is part of the Keychain's contents, so it stays as this version writes it.
    @Test func recordIsStoredAsSortedJSON() throws {
        let json = String(decoding: try SystemKeyItems.encoder.encode(KeyRecord(key)), as: UTF8.self)

        let publicKey = key.publicKey.wireRepresentation.base64EncodedString().replacing("/", with: "\\/")
        #expect(
            json
                == #"{"comment":"florian@iphone","createdAt":814000000.5,"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","#
                + #""kind":"ed25519","publicKey":"\#(publicKey)","signingPolicy":"everyUse","version":1}"#)
    }

    @Test func itemWithoutARecordOrForAnotherKeyIsLeftOut() throws {
        let record = try SystemKeyItems.encoder.encode(KeyRecord(key))

        #expect(SystemKeyItems.record(in: [kSecAttrAccount as String: key.id.uuidString]) == nil)
        #expect(
            SystemKeyItems.record(in: [
                kSecAttrAccount as String: UUID().uuidString, kSecAttrGeneric as String: record,
            ]) == nil)
        #expect(
            SystemKeyItems.record(in: [
                kSecAttrAccount as String: key.id.uuidString, kSecAttrGeneric as String: Data("{".utf8),
            ]) == nil)
    }
}
