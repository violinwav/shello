import Foundation
import Network
import Synchronization
import os

/// A byte stream to an address and port as a server reaches them, over a connection: what a forward
/// pipes each connection it accepts into. `SSHTunnel` is one (`SSHConnection.openTunnel(to:port:)`);
/// tests stand in for it.
public protocol ForwardTunnel: AnyObject, Sendable {
    /// Sends `bytes` after what was sent before, without waiting.
    func send(_ bytes: [UInt8])
    /// How many of the bytes sent the far end's window has not taken yet.
    var unsentByteCount: Int { get }
    /// Returns once every byte sent so far has been taken.
    func drain() async throws
    /// Ends what is sent, as a TCP half-close does; the far end may still send.
    func finish()
    /// The far end's next bytes, or nil once it ended its side or the tunnel was closed.
    func receive() async throws -> [UInt8]?
    /// Closes the tunnel at once, in both directions.
    func close() async
}

extension SSHTunnel: ForwardTunnel {}

/// Opens a tunnel to `address` and `port` as the server reaches them, over the tab's connection.
public typealias ForwardTunnelOpener = @Sendable (_ address: String, _ port: UInt16) async throws -> any ForwardTunnel

/// A port forward's listener (README section 4, STACK section 7.1): it listens through `NWListener`
/// on 127.0.0.1 only, never on another interface, and carries each connection it accepts through a
/// tunnel of its own over the connection, as OpenSSH's `LocalForward` and `DynamicForward` do: to a
/// fixed destination, or to the one the client asks for through SOCKS5 (`SOCKS5Handshake`).
///
/// Both directions keep flow control, so that a slow side never fills memory:
/// - What the client sends goes into the tunnel, and the listener reads no more from the client
///   while the tunnel holds `maximumUnsentByteCount` or more that the far end's window has not
///   taken: the client's TCP window fills, and it slows down.
/// - What the far end sends is read from the tunnel one chunk at a time, each once the client's
///   connection has taken the one before: the SSH channel's window fills, and the server slows down.
///
/// Other apps on the device can reach a loopback listener too, so the tab makes one only while it
/// needs it, and stops it when its connection goes (STACK section 7.1).
public final class PortForwardListener: Sendable {
    /// Where the connections go.
    public enum Target: Hashable, Sendable {
        /// To `address` and `port` as the server reaches them: a local forward.
        case destination(address: String, port: UInt16)
        /// To where each client asks through SOCKS5: a dynamic forward.
        case socks
    }

    /// What happens to the connections the listener accepted, as it happens.
    public enum Activity: Equatable, Sendable {
        /// A connection reached its destination: its tunnel is open.
        case opened
        /// A connection that reached its destination ended.
        case closed
        /// A connection did not reach its destination, for this reason, said in a sentence.
        case failed(String)
        /// The listener stopped listening by itself, for this reason, said in a sentence.
        case stoppedListening(String)
    }

    /// The port asked for; 0 for any port, as tests ask.
    public let requestedPort: UInt16
    public let target: Target

    /// How many bytes from the client the tunnel may hold before the listener stops reading from the
    /// client.
    static let maximumUnsentByteCount = 512 * 1024
    /// The most the listener reads from either side at once.
    static let chunkSize = 64 * 1024

    private let open: ForwardTunnelOpener
    private let report: @Sendable (Activity) -> Void
    private let queue = DispatchQueue(label: "ch.shello.forward", qos: .userInitiated)
    private let state = Mutex(State())

    private struct State {
        var listener: NWListener?
        var port: UInt16?
        var isStopped = false
        var connections: [ObjectIdentifier: ForwardedConnection] = [:]
        var acceptedCount = 0
        var maximumHeldByteCount = 0
        /// Whether the system let go of the listener's port, or it never had it.
        var hasLetGo = true
        var letGoWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Forwards")

    /// A listener on 127.0.0.1, port `port`, or any port for 0, that sends its connections to
    /// `target` through tunnels from `open`, and tells `report` what happens to them. It listens once
    /// `start()` returns.
    public init(
        port: UInt16, target: Target, open: @escaping ForwardTunnelOpener,
        report: @escaping @Sendable (Activity) -> Void = { _ in }
    ) {
        requestedPort = port
        self.target = target
        self.open = open
        self.report = report
    }

    deinit {
        stop()
    }

    /// Listens on 127.0.0.1, and returns the port it listens on.
    /// - Throws: `ForwardListenError.portInUse` when another listener, of another tab or app, has the
    ///   port; `.stopped` when `stop()` came first; or another `ForwardListenError` with the system's
    ///   reason.
    @discardableResult
    public func start() async throws(ForwardListenError) -> UInt16 {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // The loopback's IPv4 address only: never another interface, and so never the network
        // (STACK section 7.1). Without endpoint reuse, a port another listener has fails.
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ForwardListenError(error, port: requestedPort)
        }
        let isStopped = state.withLock { state in
            if !state.isStopped {
                state.listener = listener
                state.hasLetGo = false
            }
            return state.isStopped
        }
        guard !isStopped else { throw .stopped }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let requestedPort = requestedPort
        let result: Result<UInt16, ForwardListenError> = await withCheckedContinuation { continuation in
            let once = Mutex(false)
            let finish: @Sendable (Result<UInt16, ForwardListenError>) -> Void = { result in
                let isFirst = once.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirst { continuation.resume(returning: result) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    finish(.success(listener?.port?.rawValue ?? requestedPort))
                case .failed(let error):
                    finish(.failure(ForwardListenError(error, port: requestedPort)))
                    self?.stoppedListening(ForwardListenError(error, port: requestedPort))
                    listener?.cancel()
                case .cancelled:
                    finish(.failure(.stopped))
                    self?.letGo()
                case .waiting(let error):
                    // A listener waits only when the network it needs is missing, which the loopback
                    // never is: give up rather than listen later, unseen.
                    finish(.failure(ForwardListenError(error, port: requestedPort)))
                    listener?.cancel()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        let port = try result.get()
        state.withLock { $0.port = port }
        Self.logger.info("Listening on 127.0.0.1:\(port, privacy: .public)")
        return port
    }

    /// The port the listener listens on, while it does.
    public var port: UInt16? { state.withLock(\.port) }

    /// Stops listening, and ends every connection it accepted, at once. The system lets go of the port
    /// a moment later (`stopped()`): a connection that reaches it meanwhile is reset as it is accepted,
    /// and never reaches a tunnel. Stopping again does nothing.
    public func stop() {
        let (listener, connections) = state.withLock { state in
            state.isStopped = true
            state.port = nil
            defer {
                state.listener = nil
                state.connections = [:]
            }
            return (state.listener, Array(state.connections.values))
        }
        listener?.cancel()
        for connection in connections {
            connection.stop()
        }
    }

    /// Returns once the system has let go of the listener's port, after `stop()`: a listener on the
    /// same port, such as the one a reconnect starts, can have it then.
    public func stopped() async {
        await withCheckedContinuation { continuation in
            let hasLetGo = state.withLock { state in
                if !state.hasLetGo { state.letGoWaiters.append(continuation) }
                return state.hasLetGo
            }
            if hasLetGo { continuation.resume() }
        }
    }

    private func letGo() {
        let waiters = state.withLock { state in
            state.hasLetGo = true
            defer { state.letGoWaiters = [] }
            return state.letGoWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// How many of the connections it accepted are still open.
    public var openConnectionCount: Int { state.withLock { $0.connections.count } }

    /// How many connections it accepted in all.
    public var acceptedConnectionCount: Int { state.withLock(\.acceptedCount) }

    /// The most bytes it held for one connection at any moment, in either direction, waiting for the
    /// other side to take them: what flow control keeps bounded.
    public var maximumHeldByteCount: Int { state.withLock(\.maximumHeldByteCount) }

    private func stoppedListening(_ error: ForwardListenError) {
        let wasListening = state.withLock { state in
            defer { state.port = nil }
            return state.port != nil && !state.isStopped
        }
        if wasListening {
            Self.logger.notice("Stopped listening: \(error.description, privacy: .public)")
            report(.stoppedListening(error.description))
        }
    }

    private func accept(_ client: NWConnection) {
        let connection = ForwardedConnection(client: client)
        let id = ObjectIdentifier(connection)
        let isAccepted = state.withLock { state in
            guard !state.isStopped else { return false }
            state.connections[id] = connection
            state.acceptedCount += 1
            return true
        }
        guard isAccepted else {
            client.forceCancel()
            return
        }
        let (target, open, report, queue) = (target, open, report, queue)
        Task { [weak self] in
            await connection.run(
                on: queue, to: target, opening: open, reporting: report,
                holding: { [weak self] count in self?.held(count) })
            self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
        }
    }

    private func held(_ count: Int) {
        state.withLock { $0.maximumHeldByteCount = max($0.maximumHeldByteCount, count) }
    }
}

/// Why a forward does not listen, said in a sentence the Connection sheet shows.
public enum ForwardListenError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Another listener has the port: one of another tab's forwards, or another app's.
    case portInUse(UInt16)
    /// The system does not let Shello listen on the port.
    case notPermitted(UInt16)
    /// The server refused to listen on its port for a remote forward. Its answer says no more: it
    /// may not allow remote forwards (`AllowTcpForwarding`), or it could not listen on the port,
    /// which another program has, or which only its administrator may take.
    case serverRefused(UInt16)
    /// The forward was stopped before it listened.
    case stopped
    /// Another reason, as the system said it.
    case failed(String)

    init(_ error: any Error, port: UInt16) {
        switch error as? NWError {
        case .posix(.EADDRINUSE)?: self = .portInUse(port)
        case .posix(.EACCES)?, .posix(.EPERM)?: self = .notPermitted(port)
        case .posix(let code)?: self = .failed(SSHError.message(forErrno: code.rawValue))
        default: self = .failed(error.localizedDescription)
        }
    }

    public var description: String {
        switch self {
        case .portInUse(let port): "Port \(port) is in use by another tab or app."
        case .notPermitted(let port): "Shello isn’t allowed to listen on port \(port)."
        case .serverRefused(let port):
            "The server refused to listen on its port \(port). It may not allow remote forwards, or the port may be "
                + "in use or reserved."
        case .stopped: "The forward stopped."
        case .failed(let reason): "It couldn’t listen: \(reason)."
        }
    }
}
