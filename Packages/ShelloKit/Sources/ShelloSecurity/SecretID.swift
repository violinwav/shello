import Foundation
import ShelloModel

/// Which secret a Keychain item holds, and whose it is (README section 13).
///
/// A secret belongs to a host or an SSH key and is found by its owner's identifier, which is all the
/// reference there is: a host keeps no field of its own for its password, so nothing about the
/// password reaches the database or an export.
public struct SecretID: Hashable, Sendable {
    public enum Kind: Hashable, Sendable, CaseIterable {
        /// The password a host signs in with (README section 3).
        case password
        /// The passphrase of an SSH key.
        case passphrase
    }

    public var kind: Kind
    /// The identifier of the host or SSH key the secret belongs to.
    public var owner: UUID

    public init(kind: Kind, owner: UUID) {
        self.kind = kind
        self.owner = owner
    }

    /// The password of the host `hostID`.
    public static func password(of hostID: Host.ID) -> SecretID {
        SecretID(kind: .password, owner: hostID)
    }

    /// The passphrase of the SSH key `keyID`.
    public static func passphrase(of keyID: UUID) -> SecretID {
        SecretID(kind: .passphrase, owner: keyID)
    }

    /// Every secret a host can have, which goes when the host goes.
    static func secrets(ofHost hostID: Host.ID) -> [SecretID] {
        [.password(of: hostID)]
    }

    /// The Keychain item's service: one per kind, so that a host's password and an SSH key's
    /// passphrase are separate items even if their owners' identifiers were ever the same.
    var service: String {
        switch kind {
        case .password: "ch.shello.password"
        case .passphrase: "ch.shello.passphrase"
        }
    }

    /// The Keychain item's account: the owner's identifier.
    var account: String { owner.uuidString }
}
