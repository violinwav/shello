import Foundation
import LocalAuthentication
import Security
import Synchronization

/// SSH keys' items in memory, for tests, SwiftUI previews and UI tests: they go when the items go.
/// Like the iOS Simulator's Keychain, they hand out key data to any context, whether or not the item
/// requires the user's presence.
final class MemoryKeyItems: KeyItems {
    private struct Item: Sendable {
        let record: KeyRecord
        let keyData: Secret
        let requiresUserPresence: Bool
    }

    private let items = Mutex<[UUID: Item]>([:])

    func add(_ record: KeyRecord, keyData: Secret, requiresUserPresence: Bool) throws {
        let item = Item(record: record, keyData: Self.copy(of: keyData), requiresUserPresence: requiresUserPresence)
        let added = items.withLock { items in
            guard items[record.id] == nil else { return false }
            items[record.id] = item
            return true
        }
        guard added else { throw KeychainError(status: errSecDuplicateItem) }
    }

    func records() -> [KeyRecord] {
        items.withLock { $0.values.map(\.record) }
    }

    func keyData(of id: UUID, context: LAContext) -> Secret? {
        items.withLock { $0[id]?.keyData }.map(Self.copy(of:))
    }

    func remove(_ id: UUID) {
        _ = items.withLock { $0.removeValue(forKey: id) }
    }

    /// Whether the item `id` needs the user's presence before its key data reads, as the Keychain
    /// would ask; nil if there is no such item.
    func requiresUserPresence(_ id: UUID) -> Bool? {
        items.withLock { $0[id]?.requiresUserPresence }
    }

    private static func copy(of secret: Secret) -> Secret {
        unsafe secret.withUnsafeBytes { unsafe Secret(copying: $0) }
    }
}
