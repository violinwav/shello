import Foundation
import Network
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloTmux

/// What a tab connects with: the network and the server behind it. `HostConnector` is the app's;
/// tests stand in for the network and the server, to drop connections when they choose.
public protocol TabConnector: Sendable {
    /// Connects to `host`'s server, checks its host key and signs in, reporting each step to
    /// `progress`, as `HostConnector.connect(to:algorithms:progress:askToTrust:answer:)` does.
    func openConnection(
        to host: Host, progress: @escaping @Sendable (ConnectStep) async -> Void,
        askToTrust: @escaping @Sendable (Server, HostKey) async -> Bool,
        answer: @escaping @Sendable (KeyboardInteractiveChallenge) async -> [Secret]?
    ) async throws -> any TabConnection

    /// Replaces the host key trusted for `server` with the one it presented, once the user confirmed
    /// it and authenticated (README section 3).
    func replaceTrustedKey(_ trusted: TrustedHostKey, with presented: HostKey, of server: Server) async throws
}

/// A signed-in connection behind a tab (GLOSSARY: Connection): `SSHConnection`, or a test's stand-in.
/// Its hidden channels check the server's tmux before the shell starts (README section 8).
public protocol TabConnection: HiddenChannels {
    /// The key exchange the connection negotiated (README section 14).
    var keyExchange: KeyExchange? { get async }

    /// What happens to the network under the connection, as `SSHConnection.pathEvents` says.
    var pathEvents: AsyncStream<SSHConnection.PathEvent> { get }

    /// Opens the user's login shell, on a pseudo-terminal of `host`'s terminal type and `size`.
    func openShell(for host: Host, size: TerminalSize) async throws -> any TerminalByteStream

    /// Checks that the server answers, and returns the round trip (README section 4).
    func keepalive() async throws -> Duration

    /// Closes the connection, cleanly, at once.
    func close() async
}

extension HostConnector: TabConnector {
    public func openConnection(
        to host: Host, progress: @escaping @Sendable (ConnectStep) async -> Void,
        askToTrust: @escaping @Sendable (Server, HostKey) async -> Bool,
        answer: @escaping @Sendable (KeyboardInteractiveChallenge) async -> [Secret]?
    ) async throws -> any TabConnection {
        try await connect(to: host, progress: progress, askToTrust: askToTrust, answer: answer)
    }
}

extension SSHConnection: TabConnection {
    public func openShell(for host: Host, size: TerminalSize) async throws -> any TerminalByteStream {
        try await openShell(terminalType: host.terminalType, size: size)
    }
}

/// Whether the device can reach the network at all (`NWPathMonitor`, STACK section 7.1). While it
/// cannot, a tab that lost its connection waits instead of trying in vain, and tries again as soon
/// as the network is back.
public protocol NetworkMonitor: Sendable {
    /// Whether the network can be used now, then again on every change, until the iteration ends.
    func updates() -> AsyncStream<Bool>
}

/// The device's network, as `NWPathMonitor` reports it.
public struct SystemNetworkMonitor: NetworkMonitor {
    public init() {}

    public func updates() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            // A path that requires a connection, such as VPN On Demand's, comes up as one connects:
            // connecting by name is what brings it up (TN3151).
            monitor.pathUpdateHandler = { path in continuation.yield(path.status != .unsatisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "ch.shello.network-monitor", qos: .utility))
        }
    }
}
