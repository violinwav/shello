import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloStorage
import os

/// Connects to a host's server and signs in: the first steps of a connection's lifecycle (README
/// section 4), connect, verify the host key, authenticate.
///
/// The host key is checked against Shello's trust store before anything about the user is sent
/// (README section 3). On the first connection to a server the user is asked to trust its key; a key
/// that differs from the trusted one blocks the connection. The password is read from the Keychain
/// only after that, inside the unlock window.
public struct HostConnector: Sendable {
    private let hostKeys: HostKeyRepository
    private let secrets: SecretStore

    public init(hostKeys: HostKeyRepository, secrets: SecretStore) {
        self.hostKeys = hostKeys
        self.secrets = secrets
    }

    /// Opens a connection to `host`'s server and signs in.
    /// - Parameter askToTrust: Asks the user whether to trust the server's host key, on the first
    ///   connection to the server, and returns their answer. Only then is the key trusted.
    /// - Returns: The connection, signed in. The caller closes it.
    /// - Throws: `ConnectError`; `SSHError` for the connection itself; `UnlockWindowClosed` while app
    ///   lock is engaged; `KeychainError`; or `CancellationError`.
    @concurrent
    public func connect(
        to host: Host, askToTrust: @Sendable (Server, HostKey) async -> Bool
    ) async throws -> SSHConnection {
        try Self.checkCanConnect(to: host)
        guard try secrets.contains(.password(of: host.id)) else { throw ConnectError.noPassword }
        let server = host.server
        var trustedJustNow = false
        while true {
            let connection = SSHConnection(server: server, username: host.username, connectTimeout: host.connectTimeout)
            do {
                let presented = try await connection.connect()
                if let trusted = try await hostKeys.trustedKey(of: server) {
                    guard trusted.key == presented else {
                        Self.logger.notice("Host key changed for \(server, privacy: .private)")
                        throw ConnectError.hostKeyChanged(server, trusted: trusted, presented: presented)
                    }
                } else {
                    guard await askToTrust(server, presented) else { throw ConnectError.hostKeyNotTrusted }
                    try Task.checkCancellation()
                    try await hostKeys.trust(presented, of: server)
                    trustedJustNow = true
                }
                guard let password = try secrets.secret(.password(of: host.id)) else { throw ConnectError.noPassword }
                try await connection.authenticate(password: password)
                return connection
            } catch let error as SSHError where trustedJustNow && error.isConnectionLost {
                // The server gave up waiting while the user read the fingerprint (OpenSSH waits two
                // minutes for a sign-in). The key is trusted now, so connecting again asks nothing.
                await connection.close()
                trustedJustNow = false
            } catch {
                await connection.close()
                throw error
            }
        }
    }

    /// Fails for a host Shello cannot sign in to yet, before anything goes over the network.
    private static func checkCanConnect(to host: Host) throws(ConnectError) {
        switch host.protocol {
        case .ssh, .mosh: break
        case .vnc: throw .unsupportedProtocol(.vnc)
        }
        guard !host.username.isEmpty else { throw .noUser }
        switch host.authMethod {
        case .password: break
        case .sshKey, .keyboardInteractive: throw .unsupportedAuthMethod(host.authMethod)
        }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Connect")
}

/// Why `HostConnector` did not connect.
public enum ConnectError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The server identified itself with another host key than the one the user trusted: someone may
    /// be intercepting the connection, or the server was reinstalled. Nothing about the user was
    /// sent.
    case hostKeyChanged(Server, trusted: TrustedHostKey, presented: HostKey)
    /// The user did not trust the server's host key.
    case hostKeyNotTrusted
    /// The host signs in with a password, and none is saved.
    case noPassword
    /// The host has no user to sign in as.
    case noUser
    /// The host signs in with a method that comes later: SSH keys through Shello's SSH agent and
    /// keyboard-interactive (#27).
    case unsupportedAuthMethod(AuthMethod)
    /// The host is a VNC host, which opens no terminal.
    case unsupportedProtocol(HostProtocol)

    public var description: String {
        switch self {
        case .hostKeyChanged(let server, _, _):
            "The host key of \(server) changed. Shello didn’t connect."
        case .hostKeyNotTrusted: "The server’s host key wasn’t trusted."
        case .noPassword: "This host has no saved password. Add it in the host’s settings."
        case .noUser: "This host has no user to sign in as. Add one in the host’s settings."
        case .unsupportedAuthMethod(.keyboardInteractive):
            "Signing in with keyboard-interactive isn’t available yet. Choose Password in the host’s settings."
        case .unsupportedAuthMethod:
            "Signing in with an SSH key isn’t available yet. Choose Password in the host’s settings."
        case .unsupportedProtocol: "Remote desktop isn’t available yet."
        }
    }
}

extension SSHError {
    /// Whether the connection ended under the operation, rather than the operation failing.
    var isConnectionLost: Bool {
        switch self {
        case .connectionLost, .closed: true
        default: false
        }
    }
}
