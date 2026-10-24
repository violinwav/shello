import Foundation
import Network
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloTmux

/// What a tab connects with: the network and the servers behind it. `HostConnector` is the app's;
/// tests stand in for the network and the servers, to drop connections when they choose.
public protocol TabConnector: Sendable {
    /// Connects along `route` (README section 3): to each host on it in turn, the jump hosts first,
    /// checking each one's host key and signing in to each as it says, and reports each step of
    /// each hop to `progress`, as `HostConnector.connect(along:progress:askToTrust:answer:)` does.
    /// The questions name the hop they are about.
    func openConnection(
        along route: Route, progress: @escaping @Sendable (RouteProgress) async -> Void,
        askToTrust: @escaping @Sendable (Host, HostKey) async -> Bool,
        answer: @escaping @Sendable (Host, KeyboardInteractiveChallenge) async -> [Secret]?
    ) async throws -> any TabConnection

    /// Replaces the host key trusted for `server` with the one it presented, once the user confirmed
    /// it and authenticated (README section 3).
    func replaceTrustedKey(_ trusted: TrustedHostKey, with presented: HostKey, of server: Server) async throws
}

/// A signed-in connection behind a tab (GLOSSARY: Connection): the connections along its route
/// (`RouteConnection`), one `SSHConnection` for a host without jump hosts, or a test's stand-in. It
/// works on the tab's own host. Its hidden channels check the server's tmux before the shell starts
/// (README section 8).
public protocol TabConnection: HiddenChannels {
    /// The key exchange the connection to the tab's own host negotiated (README section 14).
    var keyExchange: KeyExchange? { get async }

    /// The key exchange of each connection along the route, in its order, the tab's own host's
    /// last.
    var keyExchanges: [KeyExchange?] { get async }

    /// What happens to the network under the connection, as `SSHConnection.pathEvents` says: under
    /// the first one along the route, which Shello makes from the device.
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
        along route: Route, progress: @escaping @Sendable (RouteProgress) async -> Void,
        askToTrust: @escaping @Sendable (Host, HostKey) async -> Bool,
        answer: @escaping @Sendable (Host, KeyboardInteractiveChallenge) async -> [Secret]?
    ) async throws -> any TabConnection {
        try await connect(along: route, progress: progress, askToTrust: askToTrust, answer: answer)
    }
}

extension SSHConnection: TabConnection {
    public var keyExchanges: [KeyExchange?] {
        get async { [keyExchange] }
    }

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
