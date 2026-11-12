import Foundation
import Network
import Synchronization

/// One connection a forward carries: its connection on this device, and once both ends are there,
/// the tunnel over the SSH connection it is piped into, both ways.
/// - For a local or dynamic forward, the connection on this device is the client the listener
///   accepted on the loopback, and the tunnel is opened to the destination, the client's for SOCKS5
///   (`run(on:to:opening:reporting:holding:)`).
/// - For a remote forward, the tunnel is the channel the server opened for a connection it
///   accepted, and the connection on this device is the one Shello makes to the destination
///   (`run(on:from:to:timeout:reporting:holding:)`).
///
/// The piping keeps flow control both ways, as `PortForwardListener` describes, and ends passes
/// through as half-closes.
final class ForwardedConnection: Sendable {
    /// The connection on this device's side.
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
        guard await adopt(opened.tunnel) else { return }
        report(.opened)
        await pipe(opened.tunnel, rest: opened.rest, clientEnded: opened.clientEnded, holding: holding)
        report(.closed)
    }

    /// Connects to `destination`, as this device reaches it, within `timeout`, for the connection the
    /// server forwarded through `tunnel`; then pipes the bytes both ways until both sides ended, and
    /// closes both. A destination that does not answer closes the tunnel, and with it the server's
    /// connection: the client on the server's side reads the end. `holding` hears how many bytes the
    /// connection holds as it changes.
    func run(
        on queue: DispatchQueue, from tunnel: any ForwardTunnel, to destination: (address: String, port: UInt16),
        timeout: Duration, reporting report: @Sendable (PortForwardListener.Activity) -> Void,
        holding: @escaping @Sendable (Int) -> Void
    ) async {
        guard await adopt(tunnel) else { return }
        do {
            try await client.connect(on: queue, timeout: timeout)
        } catch {
            client.forceCancel()
            await tunnel.close()
            if !state.withLock(\.isStopped) {
                report(.failed(Self.unreachableFromDevice(destination.address, destination.port, error)))
            }
            return
        }
        report(.opened)
        await pipe(tunnel, rest: [], clientEnded: false, holding: holding)
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

    /// Keeps `tunnel` as the connection's, so that `stop()` closes it. Returns false, after closing
    /// both, if the connection was stopped already.
    private func adopt(_ tunnel: any ForwardTunnel) async -> Bool {
        let isStopped = state.withLock { state in
            state.tunnel = tunnel
            return state.isStopped
        }
        guard isStopped else { return true }
        client.forceCancel()
        await tunnel.close()
        return false
    }

    /// Pipes the bytes both ways, after `rest`, what the client sent before the tunnel was there, and
    /// with the client's end if it came with them; then closes both: the client's connection without
    /// a reset once both sides ended cleanly, with one if either failed.
    private func pipe(
        _ tunnel: any ForwardTunnel, rest: [UInt8], clientEnded: Bool, holding: @escaping @Sendable (Int) -> Void
    ) async {
        if !rest.isEmpty {
            tunnel.send(rest)
        }
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
        let destination = Self.destination(address, port)
        guard case .channelRefused(let message)? = error as? SSHError else {
            return "The server couldn’t connect to \(destination): \(error)"
        }
        return "The server couldn’t connect to \(destination): \(SSHConnection.openFailureReason(message))."
    }

    /// "Shello couldn’t connect to 192.168.1.20:80: Connection refused.", for a remote forward's
    /// destination, which this device reaches; or, when iOS kept Shello off the local network, why
    /// and where to allow it.
    static func unreachableFromDevice(_ address: String, _ port: UInt16, _ error: any Error) -> String {
        let destination = Self.destination(address, port)
        switch error {
        case DestinationFailure.localNetworkDenied:
            return "Shello couldn’t connect to \(destination). \(SSHError.localNetworkDenied.description)"
        case DestinationFailure.timedOut:
            return "Shello couldn’t connect to \(destination): it didn’t answer in time."
        case NWError.posix(let code):
            return "Shello couldn’t connect to \(destination): \(SSHError.message(forErrno: code.rawValue))."
        case NWError.dns:
            return "Shello couldn’t connect to \(destination): its name couldn’t be found."
        default:
            return "Shello couldn’t connect to \(destination): \(error.localizedDescription)"
        }
    }

    /// An address and port as people write them, an IPv6 address in brackets.
    private static func destination(_ address: String, _ port: UInt16) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
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

/// Why Shello did not reach a remote forward's destination, besides what Network.framework said.
enum DestinationFailure: Error, Equatable {
    /// Nothing answered within the time allowed.
    case timedOut
    /// iOS held the connection back for Local Network access all that time: the user has not
    /// allowed it, or not answered its question yet (TN3179).
    case localNetworkDenied
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
    /// Starts the connection, and returns once it is ready, as a connection Shello makes to a remote
    /// forward's destination: TCP's connection timeout, or `timeout` if that is shorter, bounds it.
    /// A connection that waits fails at once, as a refused one does, unless iOS holds it back for
    /// Local Network access (TN3179), as while its question is on screen: then it waits until
    /// `timeout`, and fails as `DestinationFailure.localNetworkDenied` if iOS held it back all along.
    /// - Throws: `NWError`, `DestinationFailure`, or `CancellationError` if the connection was
    ///   cancelled first.
    func connect(on queue: DispatchQueue, timeout: Duration) async throws {
        let result: Result<Void, any Error> = await withCheckedContinuation { continuation in
            let state = Mutex((isDone: false, isWaitingForLocalNetwork: false))
            let finish: @Sendable (Result<Void, any Error>) -> Void = { result in
                let isFirst = state.withLock { state in
                    defer { state.isDone = true }
                    return !state.isDone
                }
                if isFirst { continuation.resume(returning: result) }
            }
            stateUpdateHandler = { [weak self] change in
                switch change {
                case .ready:
                    finish(.success(()))
                case .waiting(let error):
                    if self?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        state.withLock { $0.isWaitingForLocalNetwork = true }
                    } else {
                        finish(.failure(error))
                    }
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            let (seconds, attoseconds) = timeout.components
            let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
            queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) {
                let isWaitingForLocalNetwork = state.withLock(\.isWaitingForLocalNetwork)
                finish(
                    .failure(
                        isWaitingForLocalNetwork ? DestinationFailure.localNetworkDenied : DestinationFailure.timedOut))
            }
            start(queue: queue)
        }
        try result.get()
    }

    /// The next bytes the peer sent, up to `maximum`, and whether it ended its side after them.
    func receiveBytes(maximum: Int) async throws -> (bytes: [UInt8], isComplete: Bool) {
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
    func sendBytes(_ bytes: [UInt8]) async throws {
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
    func sendEnd() async {
        await withCheckedContinuation { continuation in
            send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
