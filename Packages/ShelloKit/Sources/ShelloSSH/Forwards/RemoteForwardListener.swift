import Foundation
import Network
import ShelloModel
import Synchronization
import os

/// What a remote forward asks of its connection: that the server listen, and hand over the
/// connections it accepts, and that it stop. `SSHConnection` does it with `tcpip-forward`; tests
/// stand in for it.
public protocol RemoteForwarding: Sendable {
    /// Asks the server to listen on `port` of `bindAddress`, as it goes to the server, and returns
    /// the tunnels of the connections it forwards, as they come, as
    /// `SSHConnection.requestRemoteForward(bindAddress:port:)` does.
    func requestRemoteForward(bindAddress: String, port: UInt16) async throws -> AsyncStream<any ForwardTunnel>
    /// Asks the server to stop listening on `port` of `bindAddress`, as
    /// `SSHConnection.cancelRemoteForward(bindAddress:port:)` does.
    func cancelRemoteForward(bindAddress: String, port: UInt16) async
}

extension SSHConnection: RemoteForwarding {}

/// A remote forward (README section 4, STACK section 7.1), as OpenSSH's `RemoteForward` and `ssh -R`:
/// the server listens on a port of its own, and each connection it accepts comes back over the SSH
/// connection, in a `forwarded-tcpip` channel, to a destination that this device reaches, which
/// Shello connects to with Network.framework. A destination that does not answer closes that one
/// channel, and the server's client reads the end.
///
/// Both directions keep the flow control of `PortForwardListener`: Shello reads no more from the
/// destination while the channel holds `PortForwardListener.maximumUnsentByteCount` that the server
/// has not taken, and reads the channel one chunk at a time, each once the destination took the one
/// before.
///
/// Nothing listens on this device, so no other app can reach a remote forward: it lasts as long as
/// the tab's connection, Shello's background time included (STACK section 7.1).
public final class RemoteForwardListener: Sendable {
    /// The port the server listens on.
    public let port: UInt16
    /// The address the server listens on, as the forward has it: empty for the server's loopback,
    /// `*` for all of its addresses (`PortForward.Kind.remote`).
    public let bindAddress: String
    /// Where each connection goes, as this device reaches it.
    public let destination: ForwardDestination

    /// How long Shello waits for the destination to answer each connection.
    static let destinationTimeout = Duration.seconds(15)

    private let forwarding: any RemoteForwarding
    private let report: @Sendable (PortForwardListener.Activity) -> Void
    private let queue = DispatchQueue(label: "ch.shello.remote-forward", qos: .userInitiated)
    private let state = Mutex(State())

    private struct State {
        var isStopped = false
        /// Whether the server was asked to listen: a stop then asks it to stop.
        var wasRequested = false
        var isListening = false
        /// Takes the connections the server forwards, while it listens.
        var accepting: Task<Void, Never>?
        /// The cancel a stop sent, until the server answered it.
        var cancelling: Task<Void, Never>?
        var connections: [ObjectIdentifier: ForwardedConnection] = [:]
        var acceptedCount = 0
        var maximumHeldByteCount = 0
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Forwards")

    /// A remote forward that has the server listen on `port` of `bindAddress` over `forwarding`, and
    /// sends each connection to `destination`, and tells `report` what happens to them. The server
    /// listens once `start()` returns.
    public init(
        port: UInt16, bindAddress: String, destination: ForwardDestination, over forwarding: any RemoteForwarding,
        report: @escaping @Sendable (PortForwardListener.Activity) -> Void = { _ in }
    ) {
        self.port = port
        self.bindAddress = bindAddress
        self.destination = destination
        self.forwarding = forwarding
        self.report = report
    }

    deinit {
        stop()
    }

    /// The address that goes to the server for `bindAddress`, as OpenSSH's client sends it:
    /// `localhost` for none, the server's loopback; an empty address for `*`, all of its addresses;
    /// any other as it is.
    public static func requestedAddress(for bindAddress: String) -> String {
        switch bindAddress {
        case "": "localhost"
        case PortForward.allAddresses: ""
        default: bindAddress
        }
    }

    /// Asks the server to listen, and returns the port it listens on once it does.
    /// - Throws: `ForwardListenError.serverRefused` when the server refused, `.stopped` when `stop()`
    ///   came first or the connection ended, or `.failed` with another reason.
    @discardableResult
    public func start() async throws(ForwardListenError) -> UInt16 {
        let isStopped = state.withLock { state in
            state.wasRequested = !state.isStopped
            return state.isStopped
        }
        guard !isStopped else { throw .stopped }
        let channels: AsyncStream<any ForwardTunnel>
        do {
            channels = try await forwarding.requestRemoteForward(
                bindAddress: Self.requestedAddress(for: bindAddress), port: port)
        } catch {
            throw ForwardListenError(remote: error, port: port)
        }
        let accepting = Task { [weak self] in
            for await tunnel in channels {
                guard let self else {
                    await tunnel.close()
                    continue
                }
                self.accept(tunnel)
            }
            self?.channelsEnded()
        }
        let isListening = state.withLock { state in
            guard !state.isStopped else { return false }
            state.isListening = true
            state.accepting = accepting
            return true
        }
        guard isListening else {
            // Stopped while the server answered: the stop's cancel ends the server's listening.
            accepting.cancel()
            throw .stopped
        }
        Self.logger.info("The server listens on port \(self.port, privacy: .public) for a remote forward")
        return port
    }

    /// Whether the server listens for the forward.
    public var isListening: Bool { state.withLock(\.isListening) }

    /// Stops at once: the connections the server forwards from now on are closed, those open end, and
    /// the server is asked to stop listening (`cancel-tcpip-forward`), which `stopped()` waits for.
    /// Stopping again does nothing.
    public func stop() {
        let (accepting, connections, cancels) = state.withLock { state in
            let cancels = state.wasRequested && !state.isStopped
            state.isStopped = true
            state.isListening = false
            defer {
                state.accepting = nil
                state.connections = [:]
            }
            return (state.accepting, Array(state.connections.values), cancels)
        }
        accepting?.cancel()
        for connection in connections {
            connection.stop()
        }
        guard cancels else { return }
        let (forwarding, bindAddress, port) = (forwarding, Self.requestedAddress(for: bindAddress), port)
        let cancelling = Task { await forwarding.cancelRemoteForward(bindAddress: bindAddress, port: port) }
        state.withLock { $0.cancelling = cancelling }
    }

    /// Returns once the server answered the cancel that `stop()` sent, or the connection ended: the
    /// tab's connection can close then, its cancel sent.
    public func stopped() async {
        await state.withLock(\.cancelling)?.value
    }

    /// How many of the connections it took are still open.
    public var openConnectionCount: Int { state.withLock { $0.connections.count } }

    /// How many connections the server forwarded to it in all.
    public var acceptedConnectionCount: Int { state.withLock(\.acceptedCount) }

    /// The most bytes it held for one connection at any moment, in either direction, waiting for the
    /// other side to take them: what flow control keeps bounded.
    public var maximumHeldByteCount: Int { state.withLock(\.maximumHeldByteCount) }

    /// The server forwarded a connection: Shello connects to the destination for it, and pipes it.
    private func accept(_ tunnel: any ForwardTunnel) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(Self.destinationTimeout.components.seconds)
        let client = NWConnection(
            host: NWEndpoint.Host(destination.address), port: NWEndpoint.Port(rawValue: destination.port) ?? .any,
            using: NWParameters(tls: nil, tcp: tcp))
        let connection = ForwardedConnection(client: client)
        let id = ObjectIdentifier(connection)
        let isAccepted = state.withLock { state in
            guard !state.isStopped else { return false }
            state.connections[id] = connection
            state.acceptedCount += 1
            return true
        }
        guard isAccepted else {
            Task { await tunnel.close() }
            return
        }
        let (destination, report, queue) = ((destination.address, destination.port), report, queue)
        Task { [weak self] in
            await connection.run(
                on: queue, from: tunnel, to: destination, timeout: Self.destinationTimeout, reporting: report,
                holding: { [weak self] count in self?.held(count) })
            self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
        }
    }

    private func held(_ count: Int) {
        state.withLock { $0.maximumHeldByteCount = max($0.maximumHeldByteCount, count) }
    }

    /// The server's connections ended without a stop: the SSH connection ended.
    private func channelsEnded() {
        let wasListening = state.withLock { state in
            defer { state.isListening = false }
            return state.isListening && !state.isStopped
        }
        if wasListening {
            Self.logger.notice("A remote forward stopped: its connection ended")
            report(.stoppedListening("The connection ended."))
        }
    }
}

extension ForwardListenError {
    /// The error for a remote forward the server did not listen for, from what the connection
    /// threw.
    init(remote error: any Error, port: UInt16) {
        switch error {
        case is CancellationError, SSHError.closed, SSHError.connectionLost:
            self = .stopped
        case SSHError.channelRefused:
            self = .serverRefused(port)
        default:
            let reason = String(describing: error)
            self = .failed(reason.hasSuffix(".") ? String(reason.dropLast()) : reason)
        }
    }
}
