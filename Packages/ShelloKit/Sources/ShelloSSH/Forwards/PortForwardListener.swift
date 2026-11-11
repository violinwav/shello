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

    /// Stops listening, and ends every connection it accepted, at once. Stopping again does nothing.
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
        case .stopped: "The forward stopped."
        case .failed(let reason): "It couldn’t listen: \(reason)."
        }
    }
}

/// One connection a forward accepted: its client's connection on the loopback, and once the
/// destination is reached, the tunnel it is piped into, both ways.
private final class ForwardedConnection: Sendable {
    let client: NWConnection
    private let state = Mutex<(tunnel: (any ForwardTunnel)?, isStopped: Bool)>((nil, false))

    init(client: NWConnection) {
        self.client = client
    }

    /// Reaches `target` through a tunnel from `open`, pipes the bytes both ways until both sides
    /// ended, then closes both. `holding` hears how many bytes the connection holds as it changes.
    func run(
        on queue: DispatchQueue, to target: PortForwardListener.Target, opening open: ForwardTunnelOpener,
        reporting report: @Sendable (PortForwardListener.Activity) -> Void, holding: @escaping @Sendable (Int) -> Void
    ) async {
        client.start(queue: queue)
        let opened: (tunnel: any ForwardTunnel, rest: [UInt8], clientEnded: Bool)
        do {
            opened = try await reach(target, opening: open)
        } catch {
            // Closed as OpenSSH closes it, without a reset: the client reads the end.
            client.cancel()
            if !state.withLock(\.isStopped), !(error is CancellationError) {
                report(.failed(Self.reason(error, target: target)))
            }
            return
        }
        let tunnel = opened.tunnel
        let isStopped = state.withLock { state in
            state.tunnel = tunnel
            return state.isStopped
        }
        guard !isStopped else {
            client.forceCancel()
            await tunnel.close()
            return
        }
        report(.opened)
        if !opened.rest.isEmpty {
            tunnel.send(opened.rest)
        }
        let clientEnded = opened.clientEnded
        let isClean = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.pipeClient(to: tunnel, clientEnded: clientEnded, holding: holding) }
            group.addTask { await self.pipe(tunnel, toClientHolding: holding) }
            var isClean = true
            for await succeeded in group where !succeeded {
                // One side failed: the other ends too.
                isClean = false
                client.forceCancel()
                await tunnel.close()
            }
            return isClean
        }
        if isClean {
            client.cancel()
        }
        await tunnel.close()
        report(.closed)
    }

    /// Ends the connection at once: the client's connection resets, and the tunnel closes.
    func stop() {
        let tunnel = state.withLock { state in
            state.isStopped = true
            return state.tunnel
        }
        client.forceCancel()
        if let tunnel {
            Task { await tunnel.close() }
        }
    }

    /// The tunnel to the destination: `target`'s, or the one the client asks for through SOCKS5,
    /// whose reply says whether the server reached it. Returns what the client sent after its
    /// request, and whether it ended its side with it.
    private func reach(_ target: PortForwardListener.Target, opening open: ForwardTunnelOpener) async throws -> (
        tunnel: any ForwardTunnel, rest: [UInt8], clientEnded: Bool
    ) {
        switch target {
        case .destination(let address, let port):
            return (try await open(address, port), [], false)
        case .socks:
            var handshake = SOCKS5Handshake()
            while true {
                let (bytes, isComplete) = try await client.receiveBytes(maximum: PortForwardListener.chunkSize)
                let step = handshake.receive(bytes)
                if !step.send.isEmpty {
                    try await client.sendBytes(step.send)
                }
                switch step.outcome {
                case .pending:
                    guard !isComplete else { throw ForwardFailure.socksClientEnded }
                case .failed(let failure):
                    await client.sendEnd()
                    throw ForwardFailure.socks(failure)
                case .connect(let destination, let rest):
                    let tunnel: any ForwardTunnel
                    do {
                        tunnel = try await open(destination.address, destination.port)
                    } catch {
                        try? await client.sendBytes(SOCKS5.Reply(openFailure: error).bytes)
                        await client.sendEnd()
                        throw ForwardFailure.socksDestination(destination, error)
                    }
                    do {
                        try await client.sendBytes(SOCKS5.Reply.succeeded.bytes)
                    } catch {
                        await tunnel.close()
                        throw error
                    }
                    return (tunnel, rest, isComplete)
                }
            }
        }
    }

    /// Passes what the client sends into the tunnel, then the end of it. Reads no more from the client
    /// while the tunnel holds too much that the far end has not taken. Returns false if either side
    /// failed.
    private func pipeClient(
        to tunnel: any ForwardTunnel, clientEnded: Bool, holding: @Sendable (Int) -> Void
    ) async -> Bool {
        guard !clientEnded else {
            tunnel.finish()
            return true
        }
        do {
            while true {
                let (bytes, isComplete) = try await client.receiveBytes(maximum: PortForwardListener.chunkSize)
                if !bytes.isEmpty {
                    tunnel.send(bytes)
                    let unsent = tunnel.unsentByteCount
                    holding(unsent)
                    if unsent >= PortForwardListener.maximumUnsentByteCount {
                        try await tunnel.drain()
                    }
                }
                if isComplete {
                    tunnel.finish()
                    return true
                }
            }
        } catch {
            return false
        }
    }

    /// Passes what the far end sends to the client, a chunk at a time, each once the client's
    /// connection took the one before, then the end of it. Returns false if either side failed.
    private func pipe(_ tunnel: any ForwardTunnel, toClientHolding holding: @Sendable (Int) -> Void) async -> Bool {
        do {
            while let bytes = try await tunnel.receive() {
                holding(bytes.count)
                try await client.sendBytes(bytes)
            }
            await client.sendEnd()
            return true
        } catch {
            return false
        }
    }

    /// Why a connection did not reach its destination, for the Connection sheet.
    private static func reason(_ error: any Error, target: PortForwardListener.Target) -> String {
        switch error {
        case ForwardFailure.socks(let failure):
            return failure.reason
        case ForwardFailure.socksClientEnded:
            return "A SOCKS client closed its connection before it said where to connect."
        case ForwardFailure.socksDestination(let destination, let error):
            return unreachable(destination.address, destination.port, error)
        default:
            if case .destination(let address, let port) = target {
                return unreachable(address, port, error)
            }
            return String(describing: error)
        }
    }

    /// "The server couldn’t connect to db.internal:5432: Connection refused."
    private static func unreachable(_ address: String, _ port: UInt16, _ error: any Error) -> String {
        let destination = address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
        guard case .channelRefused(let message)? = error as? SSHError else {
            return "The server couldn’t connect to \(destination): \(error)"
        }
        return "The server couldn’t connect to \(destination): \(SSHConnection.openFailureReason(message))."
    }
}

/// Why a connection a forward accepted did not reach a destination.
private enum ForwardFailure: Error {
    /// The SOCKS5 handshake failed.
    case socks(SOCKS5.Failure)
    /// The client ended its side before its request.
    case socksClientEnded
    /// The server did not reach the destination the client asked for.
    case socksDestination(SOCKS5.Destination, any Error)
}

extension SOCKS5.Failure {
    /// The failure in a sentence, for the Connection sheet.
    var reason: String {
        switch self {
        case .notSOCKS5: "A client that doesn’t speak SOCKS5 connected."
        case .noAcceptableMethod: "A SOCKS client asked to authenticate, which Shello doesn’t offer."
        case .unsupportedCommand: "A SOCKS client asked for something other than a connection."
        case .unsupportedAddressType: "A SOCKS client gave an address of a type SOCKS5 doesn’t know."
        case .invalidDomainName: "A SOCKS client gave a name that isn’t a domain name."
        }
    }
}

extension SOCKS5.Reply {
    /// The reply for a tunnel the server did not open (RFC 4254 section 5.1): not allowed when the
    /// server forwards no TCP, connection refused, network unreachable, or host unreachable for a
    /// host it could not reach or whose name it could not resolve, as OpenSSH's message for the
    /// connect failure says; a general failure for anything else, such as a connection that ended.
    init(openFailure error: any Error) {
        guard case .channelRefused(let message)? = error as? SSHError else {
            self = .generalFailure
            return
        }
        let reason = SSHConnection.openFailureReason(message).lowercased()
        switch SSHConnection.openFailureCode(message) {
        case 1:
            // SSH_OPEN_ADMINISTRATIVELY_PROHIBITED
            self = .connectionNotAllowed
        case 2:
            // SSH_OPEN_CONNECT_FAILED, with the server's reason.
            if reason.contains("refused") {
                self = .connectionRefused
            } else if reason.contains("network is unreachable") || reason.contains("network unreachable") {
                self = .networkUnreachable
            } else {
                self = .hostUnreachable
            }
        default:
            self = .generalFailure
        }
    }
}

extension NWConnection {
    /// The next bytes the peer sent, up to `maximum`, and whether it ended its side after them.
    fileprivate func receiveBytes(maximum: Int) async throws -> (bytes: [UInt8], isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: maximum) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (content.map { Array($0) } ?? [], isComplete))
                }
            }
        }
    }

    /// Sends `bytes`, and returns once the connection has taken them.
    fileprivate func sendBytes(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(
                content: Data(bytes),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// Ends what is sent, as a TCP half-close: the peer reads the end, and may still send.
    fileprivate func sendEnd() async {
        await withCheckedContinuation { continuation in
            send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
