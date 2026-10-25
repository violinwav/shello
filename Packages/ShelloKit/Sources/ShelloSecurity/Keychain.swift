import Foundation
import LocalAuthentication
import Security

/// The Keychain items behind `SecretStore`, one per secret. `SystemKeychain` keeps them in the iOS
/// Keychain; `MemoryKeychain` keeps them in memory, for tests and previews.
///
/// Reads take the unlock window's context, so that they never ask the user again (README
/// section 13). Writes and removals take none: Shello's items need no authentication to change.
public protocol Keychain: Sendable {
    /// Stores `secret` as the item `id`, replacing the secret it held, if any.
    func store(_ secret: Secret, as id: SecretID) throws
    /// The secret of the item `id`, or nil if there is no such item.
    func secret(_ id: SecretID, context: LAContext) throws -> Secret?
    /// Whether there is an item `id`. Its secret is not read.
    func contains(_ id: SecretID, context: LAContext) throws -> Bool
    /// Removes the item `id`, if there is one.
    func remove(_ id: SecretID) throws
}

/// A Keychain operation that failed, with the Security framework's result code.
public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "\(message) (Keychain error \(status))"
    }
}
