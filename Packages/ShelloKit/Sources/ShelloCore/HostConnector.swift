import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloStorage
import os

/// Connects to a host's server and signs in: the first steps of a connection's lifecycle (README
/// section 4), connect, verify the host key, authenticate.
///
/// The connection offers the algorithm policy (README section 14), with the host key algorithms of
/// the server's trusted host key first, so that a server with several host keys identifies itself
/// with the trusted one, and a host's own lists in place of the policy's, when it has them.
///
/// The host key is checked against Shello's trust store before anything about the user is sent
/// (README section 3). On the first connection to a server the user is asked to trust its key; a key
/// that differs from the trusted one blocks the connection, until the user replaces the trusted key
/// with `replaceTrustedKey(_:with:of:)`. Only then does Shello sign in, as the host says:
/// - with its password, read from the Keychain inside the unlock window;
/// - with keyboard-interactive, whose questions the user answers;
/// - with its SSH key, through Shello's SSH agent, which signs as the key's signing policy says.
///
/// A server can ask for a further method once one succeeded, as servers with two-factor sign-in
/// do: then keyboard-interactive, the host's password or its SSH key, whichever the server takes and
/// the host has.
public struct HostConnector: Sendable {
    private let hostKeys: HostKeyRepository
    private let secrets: SecretStore
    private let keys: SSHKeyStore?
    private let authentication: any Authentication

    /// A connector that checks host keys against `hostKeys`, signs in with the passwords of
    /// `secrets` and the SSH keys of `keys`, and asks the user through `authentication` before it
    /// replaces a trusted host key.
    public init(
        hostKeys: HostKeyRepository, secrets: SecretStore, keys: SSHKeyStore? = nil,
        authentication: some Authentication = LocalAuthentication()
    ) {
        self.hostKeys = hostKeys
        self.secrets = secrets
        self.keys = keys
        self.authentication = authentication
    }

    /// Opens a connection to `host`'s server and signs in.
    /// - Parameters:
    ///   - overrides: The host's own algorithm lists. Shello has no screen for them yet (v1).
    ///   - progress: Told when the host key is checked and when signing in starts, for the screen.
    ///   - askToTrust: Asks the user whether to trust the server's host key, on the first
    ///     connection to the server, and returns their answer. Only then is the key trusted.
    ///   - answer: Asks the user a round of keyboard-interactive questions, and returns their
    ///     answers, one for each question, or nil if they cancelled.
    /// - Returns: The connection, signed in. The caller closes it.
    /// - Throws: `ConnectError`; `SSHError` for the connection itself; `UnlockWindowClosed` while app
    ///   lock is engaged; `KeychainError`; or `CancellationError`. Cancelling never waits for the
    ///   user, not even for Face ID for an SSH key that signs on every use: its prompt goes.
    @concurrent
    public func connect(
        to host: Host, algorithms overrides: AlgorithmOverrides = .none,
        progress: @Sendable (ConnectStep) async -> Void = { _ in },
        askToTrust: @Sendable (Server, HostKey) async -> Bool,
        answer: @Sendable (KeyboardInteractiveChallenge) async -> [Secret]? = { _ in nil }
    ) async throws -> SSHConnection {
        try Self.checkCanConnect(to: host)
        let sshKey = try checkCredentials(of: host)
        let server = host.server
        var trustedJustNow = false
        while true {
            let policy = try await algorithms(for: server, overriddenBy: overrides)
            let connection = SSHConnection(
                server: server, username: host.username, connectTimeout: host.connectTimeout, algorithms: policy)
            do {
                let presented = try await connection.connect()
                await progress(.verifyingHostKey)
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
                await progress(.signingIn)
                try await signIn(connection, as: host, with: host.authMethod, sshKey: sshKey, answer: answer)
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

    /// Replaces the host key trusted for `server`, `trusted`, with the key it presented now: the
    /// explicit action of README section 3, which the caller has the user confirm first. Shello then
    /// asks the user to authenticate with Face ID, Touch ID or the passcode (STACK section 7.2),
    /// every time, whether or not Shello is unlocked. A device without a passcode cannot ask anyone,
    /// so there, as with app lock, the confirmation is enough.
    /// - Throws: `UnlockError` if the user does not authenticate; `HostKeyRepositoryError` if the
    ///   key trusted for the server is not `trusted` any more.
    @concurrent
    public func replaceTrustedKey(_ trusted: TrustedHostKey, with presented: HostKey, of server: Server) async throws {
        let context = authentication.makeContext()
        defer { authentication.invalidate(context) }
        if authentication.capability(of: context) != .passcodeNotSet {
            try await authentication.authenticate(context, reason: "Replace the trusted host key of \(server).")
        }
        try await hostKeys.replace(trusted.key, with: presented, of: server)
        Self.logger.notice("Replaced the trusted host key of \(server, privacy: .private)")
    }

    /// The algorithms to offer `server`: the policy, with a host's own lists, and the host key
    /// algorithms of the server's trusted key first.
    func algorithms(
        for server: Server, overriddenBy overrides: AlgorithmOverrides
    ) async throws -> AlgorithmPolicy {
        let policy = AlgorithmPolicy.standard.overridden(by: overrides)
        guard let trusted = try await hostKeys.trustedKey(of: server) else { return policy }
        return policy.preferringAlgorithms(of: trusted.key)
    }

    // MARK: - Signing in

    /// The most methods a sign-in goes through, the first one included: a server that keeps asking
    /// for more is refused.
    private static let maximumMethods = 4

    /// Signs in with `method`, then with further methods as long as the server asks for them.
    private func signIn(
        _ connection: SSHConnection, as host: Host, with method: AuthMethod, sshKey: SSHKey?,
        answer: @Sendable (KeyboardInteractiveChallenge) async -> [Secret]?
    ) async throws {
        var method = method
        for _ in 0..<Self.maximumMethods {
            do {
                try await authenticate(connection, as: host, with: method, sshKey: sshKey, answer: answer)
                return
            } catch SSHError.partiallyAuthenticated(let methods) {
                Self.logger.info("Partly signed in; the server asks for \(methods.names, privacy: .public)")
                method = try furtherMethod(among: methods, for: host, sshKey: sshKey)
            }
        }
        throw SSHError.authenticationFailed
    }

    private func authenticate(
        _ connection: SSHConnection, as host: Host, with method: AuthMethod, sshKey: SSHKey?,
        answer: @Sendable (KeyboardInteractiveChallenge) async -> [Secret]?
    ) async throws {
        switch method {
        case .password:
            guard let password = try secrets.secret(.password(of: host.id)) else { throw ConnectError.noPassword }
            try await connection.authenticate(password: password)
        case .keyboardInteractive:
            try await connection.authenticate { challenge in
                guard let answers = await answer(challenge) else { throw ConnectError.signInCancelled }
                return answers.map { $0 as any SecretBytes }
            }
        case .sshKey:
            guard let keys, let sshKey else { throw ConnectError.noSSHKey }
            try await authenticate(connection, with: sshKey, of: keys, as: host)
        }
    }

    /// Signs in with `key` through an SSH agent of its own, which offers that key only, and goes
    /// once the sign-in is done. A key that signs on every use asks the user, naming the host.
    ///
    /// libssh waits for the agent's answers on the connection's queue, and the agent waits for the
    /// user while Face ID is up, so cancelling closes the agent: libssh reads the end of its socket,
    /// the prompt goes, and closing the tab or leaving the foreground never waits for the user.
    private func authenticate(
        _ connection: SSHConnection, with key: SSHKey, of keys: SSHKeyStore, as host: Host
    ) async throws {
        let agent = SSHAgent(keys: keys, identities: [key], reason: "Sign in to \(host.name) with “\(key.comment)”.")
        defer { agent.close() }
        do {
            let socket = try agent.listen()
            try await withTaskCancellationHandler {
                try await connection.authenticate(agentSocket: socket)
            } onCancel: {
                agent.close()
            }
        } catch SSHError.signingFailed {
            try Task.checkCancellation()
            // libssh only knows that the agent did not sign; the agent knows why.
            switch agent.signingFailure {
            case let error as UnlockError where error == .cancelled: throw ConnectError.signInCancelled
            case is UnlockError: throw ConnectError.notConfirmed
            case let error as UnlockWindowClosed: throw error
            case let error?: throw error
            case nil: throw SSHError.signingFailed
            }
        }
    }

    /// The method to sign in with next, among those the server named after a partial success:
    /// keyboard-interactive, which asks the user, or else the host's password or SSH key.
    private func furtherMethod(
        among methods: SSHAuthenticationMethods, for host: Host, sshKey: SSHKey?
    ) throws -> AuthMethod {
        if methods.contains(.keyboardInteractive) {
            return .keyboardInteractive
        }
        if methods.contains(.password), try secrets.contains(.password(of: host.id)) {
            return .password
        }
        if methods.contains(.publicKey), sshKey != nil {
            return .sshKey
        }
        throw ConnectError.furtherMethodUnavailable(methods)
    }

    // MARK: - Before connecting

    /// Fails for a host Shello cannot sign in to, before anything goes over the network.
    private static func checkCanConnect(to host: Host) throws(ConnectError) {
        switch host.protocol {
        case .ssh, .mosh: break
        case .vnc: throw .unsupportedProtocol(.vnc)
        }
        guard !host.username.isEmpty else { throw .noUser }
    }

    /// Checks that what the host signs in with is there, before anything goes over the network, and
    /// returns its SSH key, if it signs in with one.
    private func checkCredentials(of host: Host) throws -> SSHKey? {
        switch host.authMethod {
        case .password:
            guard try secrets.contains(.password(of: host.id)) else { throw ConnectError.noPassword }
            return nil
        case .keyboardInteractive:
            return nil
        case .sshKey:
            guard let keyID = host.sshKeyID, let keys else { throw ConnectError.noSSHKey }
            do {
                return try keys.signingKey(id: keyID)
            } catch SSHKeyError.keyNotFound {
                throw ConnectError.sshKeyNotOnDevice
            }
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
    /// The user cancelled signing in: a keyboard-interactive question, or Face ID for an SSH key
    /// that signs on every use.
    case signInCancelled
    /// The user did not prove that they own the device, for an SSH key that signs on every use.
    case notConfirmed
    /// The host signs in with a password, and none is saved.
    case noPassword
    /// The host signs in with an SSH key, and has none chosen.
    case noSSHKey
    /// The host's SSH key is not on this device: it was deleted, or made on another device.
    case sshKeyNotOnDevice
    /// The server asks for a further method after a partial success, among `methods`, none of which
    /// the host can sign in with.
    case furtherMethodUnavailable(SSHAuthenticationMethods)
    /// The host has no user to sign in as.
    case noUser
    /// The host is a VNC host, which opens no terminal.
    case unsupportedProtocol(HostProtocol)

    public var description: String {
        switch self {
        case .hostKeyChanged(let server, _, _):
            "The host key of \(server) changed. Shello didn’t connect."
        case .hostKeyNotTrusted: "The server’s host key wasn’t trusted."
        case .signInCancelled: "Signing in was cancelled."
        case .notConfirmed: "Shello couldn’t confirm that it’s you, so the SSH key didn’t sign."
        case .noPassword: "This host has no saved password. Add it in the host’s settings."
        case .noSSHKey: "This host has no SSH key. Choose one in the host’s settings."
        case .sshKeyNotOnDevice:
            "This host’s SSH key isn’t on this device. Choose one of this device’s keys in the host’s settings."
        case .furtherMethodUnavailable(let methods):
            "The server also asks for \(methods.names.joined(separator: " or ")), which this host doesn’t have."
        case .noUser: "This host has no user to sign in as. Add one in the host’s settings."
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
