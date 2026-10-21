import Foundation
import LocalAuthentication
import Synchronization

/// Secrets in memory, for tests and SwiftUI previews: they go when the keychain goes. It keeps a
/// copy of each secret, as the Keychain does, and never asks anyone to authenticate.
public final class MemoryKeychain: Keychain {
    private let items = Mutex<[SecretID: Secret]>([:])

    public init() {}

    public func store(_ secret: Secret, as id: SecretID) {
        let copy = Self.copy(of: secret)
        items.withLock { $0[id] = copy }
    }

    public func secret(_ id: SecretID, context: LAContext) -> Secret? {
        items.withLock { $0[id] }.map(Self.copy(of:))
    }

    public func contains(_ id: SecretID, context: LAContext) -> Bool {
        items.withLock { $0[id] != nil }
    }

    public func remove(_ id: SecretID) {
        _ = items.withLock { $0.removeValue(forKey: id) }
    }

    private static func copy(of secret: Secret) -> Secret {
        unsafe secret.withUnsafeBytes { unsafe Secret(copying: $0) }
    }
}
