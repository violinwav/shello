import Foundation
import Observation
import ShelloSecurity
import UIKit

/// One SSH key's details: its public key to copy and share, its fingerprint, and Delete. Only the
/// public key ever reaches the clipboard (README section 13).
@Observable
final class SSHKeyDetailModel {
    let store: SSHKeyStore
    let key: SSHKey
    /// Whether the public key has been copied, which the screen confirms.
    private(set) var hasCopied = false
    /// Set when deleting fails; the screen shows it and clears it.
    var actionError: String?
    private let copy: (String) -> Void

    /// The details of `key`. `copy` puts text on the clipboard; tests pass their own.
    init(store: SSHKeyStore, key: SSHKey, copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) {
        self.store = store
        self.key = key
        self.copy = copy
    }

    /// Puts the public key on the clipboard, as one line of `authorized_keys`.
    func copyPublicKey() {
        copy(key.openSSHPublicKey)
        hasCopied = true
    }

    /// Deletes the key for good, and returns whether it worked.
    func delete() -> Bool {
        do {
            try store.delete(id: key.id)
            return true
        } catch {
            SSHKeyListModel.logger.error("Could not delete an SSH key: \(error)")
            actionError = String(describing: error)
            return false
        }
    }
}
