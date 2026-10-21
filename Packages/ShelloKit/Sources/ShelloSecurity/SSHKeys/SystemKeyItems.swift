import Foundation
import LocalAuthentication
import Security
import os

/// The SSH keys' items in the iOS Keychain (STACK section 7.3). Each is a generic password, found by
/// its service and the key's identifier, that
/// - only this device can read, and only while it is unlocked
///   (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), so that it is in no backup that leaves the
///   device;
/// - is not synchronizable, so that it never syncs (ADR 0003);
/// - holds the key's record in its generic attribute and the key data as its data;
/// - for an Ed25519 key, has an access control that needs the user's presence to read the data.
///
/// The items go into Shello's Keychain access group, as `SystemKeychain`'s do.
struct SystemKeyItems: KeyItems {
    static let service = "ch.shello.ssh-key"

    func add(_ record: KeyRecord, keyData: Secret, requiresUserPresence: Bool) throws {
        let attributes = try Self.encoder.encode(record)
        let accessControl = requiresUserPresence ? try deviceOnlyAccessControl(.userPresence) : nil
        try unsafe keyData.withUnsafeBytes { bytes in
            // The item's data is the secret's own buffer, not a copy that nothing would overwrite.
            let data =
                if let base = bytes.baseAddress {
                    unsafe Data(
                        bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
                } else {
                    Data()
                }
            let item = Self.newItem(record.id, attributes: attributes, data: data, accessControl: accessControl)
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    func records() throws -> [KeyRecord] {
        var query = Self.allItems
        // Attributes only: they read without authentication, and nobody is asked anything.
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else { throw KeychainError(status: errSecDecode) }
            return items.compactMap(Self.record)
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError(status: status)
        }
    }

    func keyData(of id: UUID, context: LAContext) throws -> Secret? {
        var query = Self.query(for: id)
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return Secret(copying: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func remove(_ id: UUID) throws {
        let status = SecItemDelete(Self.query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Every SSH key's item.
    static var allItems: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    /// The item of the SSH key `id`.
    static func query(for id: UUID) -> [String: Any] {
        var query = allItems
        query[kSecAttrAccount as String] = id.uuidString
        return query
    }

    /// A new item for the key `id`, protected as the type's documentation says: by `accessControl`,
    /// which carries the protection class, or else by the protection class alone.
    static func newItem(_ id: UUID, attributes: Data, data: Data, accessControl: SecAccessControl?) -> [String: Any] {
        var item = query(for: id)
        item[kSecAttrGeneric as String] = attributes
        item[kSecValueData as String] = data
        item[kSecAttrSynchronizable as String] = false
        if let accessControl {
            item[kSecAttrAccessControl as String] = accessControl
        } else {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return item
    }

    /// The record in an item's attributes, or nil for an item this version of Shello cannot read.
    static func record(in attributes: [String: Any]) -> KeyRecord? {
        guard let data = attributes[kSecAttrGeneric as String] as? Data,
            let record = try? decoder.decode(KeyRecord.self, from: data),
            attributes[kSecAttrAccount as String] as? String == record.id.uuidString
        else {
            logger.error("Skipped an SSH key item whose record Shello cannot read")
            return nil
        }
        return record
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder = JSONDecoder()
    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "SSHKeys")
}

/// An access control for an item or a key that only this device can use, only while it is
/// unlocked, with `flags` on top.
func deviceOnlyAccessControl(_ flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
    var error: Unmanaged<CFError>?
    guard
        let accessControl = unsafe SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error)
    else {
        throw unsafe error.map { unsafe $0.takeRetainedValue() as any Error } ?? KeychainError(status: errSecParam)
    }
    return accessControl
}
