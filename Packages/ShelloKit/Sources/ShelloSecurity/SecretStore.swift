import Foundation
import ShelloModel

/// Passwords and passphrases (README section 13). They live in the Keychain only, never in the
/// database, an export or a log, and are read only inside the unlock window, with its context, so
/// that reading them never asks the user again.
///
/// A secret is found by its owner (`SecretID`): a host's password by the host's identifier.
public struct SecretStore: Sendable {
    private let keychain: any Keychain
    private let unlockWindow: UnlockWindow

    public init(keychain: some Keychain, unlockWindow: UnlockWindow) {
        self.keychain = keychain
        self.unlockWindow = unlockWindow
    }

    /// Stores `secret` as `id`, replacing the secret stored as `id` before, if any.
    /// - Throws: `UnlockWindowClosed` while app lock is engaged, or `KeychainError`.
    public func store(_ secret: Secret, as id: SecretID) throws {
        let keychain = keychain
        try unlockWindow.withAuthenticationContext { _ in try keychain.store(secret, as: id) }
    }

    /// The secret stored as `id`, or nil if there is none.
    /// - Throws: `UnlockWindowClosed` while app lock is engaged, or `KeychainError`.
    public func secret(_ id: SecretID) throws -> Secret? {
        let keychain = keychain
        return try unlockWindow.withAuthenticationContext { context in try keychain.secret(id, context: context) }
    }

    /// Whether a secret is stored as `id`. The secret itself is not read.
    /// - Throws: `UnlockWindowClosed` while app lock is engaged, or `KeychainError`.
    public func contains(_ id: SecretID) throws -> Bool {
        let keychain = keychain
        return try unlockWindow.withAuthenticationContext { context in try keychain.contains(id, context: context) }
    }

    /// Removes the secret stored as `id`, if any. Removing needs no unlock.
    /// - Throws: `KeychainError`.
    public func remove(_ id: SecretID) throws {
        try keychain.remove(id)
    }

    /// Removes every secret of the host `hostID`, that is its password. Call it when the host is
    /// deleted: its secrets go with it.
    /// - Throws: `KeychainError`.
    public func removeSecrets(ofHost hostID: Host.ID) throws {
        for id in SecretID.secrets(ofHost: hostID) {
            try keychain.remove(id)
        }
    }
}
