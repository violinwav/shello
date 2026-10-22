import ShelloCore
import ShelloSecurity
import ShelloStorage
import SwiftUI

extension EnvironmentValues {
    /// The hosts, groups and tags. The composition root opens the database once and passes its
    /// repository here; without it, the screens say that the hosts are unavailable.
    @Entry public var hostRepository: HostRepository? = nil

    /// Export and import of all non-secret data, on the same database as `hostRepository`.
    /// Without it, Settings leaves export and import out.
    @Entry public var exportRepository: ExportRepository? = nil

    /// The passwords and passphrases in the Keychain, read inside the unlock window. Without it, the
    /// host editor has no password field, and deleting a host leaves the Keychain alone.
    @Entry public var secretStore: SecretStore? = nil

    /// The SSH keys on this device. Without it, Settings leaves SSH keys out, and the host editor
    /// shows a host's SSH key without offering a choice.
    @Entry public var sshKeyStore: SSHKeyStore? = nil

    /// App lock. Without it, Settings leaves app lock out.
    @Entry public var appLock: AppLock? = nil

    /// The terminal settings of this device. Without them, Settings leaves them out, and terminals
    /// use the defaults.
    @Entry public var terminalSettings: TerminalSettings? = nil

    /// Connects to a host's server, with the trusted host keys, the passwords and the SSH keys.
    /// Without it, a host's Connect button is disabled.
    @Entry public var hostConnector: HostConnector? = nil

    /// Whether iOS's Local Network question has been explained. Without it, Connect explains
    /// nothing.
    @Entry public var localNetworkNotice: LocalNetworkNotice? = nil
}
