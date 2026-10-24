import ShelloModel
import ShelloSSH
import ShelloTmux

/// The connections along a route (README section 3), one for each hop, each through a tunnel of the
/// one before: what `HostConnector.connect(along:progress:askToTrust:answer:)` returns, and a tab's
/// connection (README section 4).
///
/// The tab works on the last connection, its own host's: the shell, the hidden channels, and the
/// keepalive, whose round trip through the jump hosts is the tab's latency. Its network is the first
/// connection's, the only one Shello makes from the device. A hop that drops ends the connections
/// after it, each as lost, so the tab sees one failure, and reconnects the whole route.
public final class RouteConnection: TabConnection {
    /// The route the connections follow.
    public let route: Route
    /// The connections, in the route's order: the first is the device's, the last the tab's own
    /// host's.
    public let connections: [SSHConnection]

    init(route: Route, connections: [SSHConnection]) {
        precondition(connections.count == route.hops.count, "one connection for each hop")
        self.route = route
        self.connections = connections
    }

    private var last: SSHConnection { connections[connections.count - 1] }

    /// The key exchange of the tab's own host's connection.
    public var keyExchange: KeyExchange? {
        get async { await last.keyExchange }
    }

    /// Each connection's key exchange, in the route's order (README section 14).
    public var keyExchanges: [KeyExchange?] {
        get async {
            var keyExchanges: [KeyExchange?] = []
            for connection in connections {
                keyExchanges.append(await connection.keyExchange)
            }
            return keyExchanges
        }
    }

    /// The network under the first connection: the only one on the device's network.
    public var pathEvents: AsyncStream<SSHConnection.PathEvent> { connections[0].pathEvents }

    public func openShell(for host: Host, size: TerminalSize) async throws -> any TerminalByteStream {
        try await last.openShell(terminalType: host.terminalType, size: size)
    }

    public func keepalive() async throws -> Duration {
        try await last.keepalive()
    }

    public func run(_ command: String) async throws -> SSHCommandResult {
        try await last.run(command)
    }

    /// Closes every connection, cleanly, the last first: each one's goodbye goes out through the
    /// hops before it.
    public func close() async {
        for connection in connections.reversed() {
            await connection.close()
        }
    }
}
