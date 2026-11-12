import Foundation
import Observation
import ShelloSecurity
import os

/// The SSH keys on this device, by name. The Keychain tells nobody when it changes, so the screen
/// reads the keys again when it shows, and after it makes or deletes one.
@Observable
final class SSHKeyListModel {
    let store: SSHKeyStore
    private(set) var keys: [SSHKey] = []
    /// Whether the keys have been read, so that an empty list really is empty.
    private(set) var hasLoaded = false
    /// Set when the keys cannot be read.
    private(set) var loadError: String?
    /// Set when deleting a key fails; the screen shows it and clears it.
    var actionError: String?

    init(store: SSHKeyStore) {
        self.store = store
    }

    /// Reads the keys again.
    func load() {
        do {
            keys = try store.keys()
            hasLoaded = true
            loadError = nil
        } catch {
            Self.logger.error("Could not read the SSH keys: \(error)")
            loadError = String(describing: error)
        }
    }

    /// Deletes `key` for good, and returns whether it worked.
    @discardableResult
    func delete(_ key: SSHKey) -> Bool {
        defer { load() }
        do {
            try store.delete(id: key.id)
            return true
        } catch {
            Self.logger.error("Could not delete an SSH key: \(error)")
            actionError = String(describing: error)
            return false
        }
    }

    static let logger = Logger(subsystem: "ch.shello.Shello", category: "SSHKeys")
}
