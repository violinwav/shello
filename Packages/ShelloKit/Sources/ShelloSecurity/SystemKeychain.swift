import Foundation
import LocalAuthentication
import Security

/// The iOS Keychain (STACK section 7.3). Each secret is a generic password item that
/// - only this device can read, and only while it is unlocked
///   (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), so it is in no backup and never moves to
///   another device;
/// - is not synchronizable, so it never syncs;
/// - lives in Shello's Keychain access group, `$(AppIdentifierPrefix)ch.shello.shared`
///   (App/Shello.entitlements), which the share extension will share (v1).
///
/// The queries leave the access group out. The Keychain puts a new item into the first group of the
/// app's `keychain-access-groups` entitlement, which is that one, and searches all of the app's
/// groups. The group's team prefix is known only once the app is signed, so the code cannot name it.
///
/// The Security framework hands a secret over in a `CFData` that Shello copies into a `Secret` and
/// releases at once; it cannot overwrite that copy.
public struct SystemKeychain: Keychain {
    public init() {}

    public func store(_ secret: Secret, as id: SecretID) throws {
        try unsafe secret.withUnsafeBytes { bytes in
            // The item's data is the secret's own buffer, not a copy that nothing would overwrite.
            let data =
                if let base = bytes.baseAddress {
                    unsafe Data(
                        bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
                } else {
                    Data()
                }
            var status = SecItemUpdate(
                Self.query(for: id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(Self.newItem(id, data: data) as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    public func secret(_ id: SecretID, context: LAContext) throws -> Secret? {
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

    public func contains(_ id: SecretID, context: LAContext) throws -> Bool {
        var query = Self.query(for: id)
        query[kSecUseAuthenticationContext as String] = context
        // An item's attributes can be read without authentication; its data cannot.
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        // An item that needs an authentication the context cannot give exists all the same.
        case errSecSuccess, errSecInteractionNotAllowed:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw KeychainError(status: status)
        }
    }

    public func remove(_ id: SecretID) throws {
        var query = Self.query(for: id)
        // A copy that syncs goes too, once the user can opt into syncing secrets (README section 15).
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// The item `id`: a generic password, by service and account.
    static func query(for id: SecretID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: id.service,
            kSecAttrAccount as String: id.account,
        ]
    }

    /// A new item `id` that holds `data`, protected as the type's documentation says.
    static func newItem(_ id: SecretID, data: Data) -> [String: Any] {
        var item = query(for: id)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        return item
    }
}
