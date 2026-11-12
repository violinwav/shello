import Foundation
import Network
import ShelloSSH
import Synchronization

/// A tunnel whose far end sends back what it is sent, then its end once it read Shello's.
final class EchoTunnel: ForwardTunnel {
    private struct State {
        var echoed: [[UInt8]] = []
        var isFinished = false
        var isClosed = false
        var version = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Whether the tunnel was closed.
    var isClosed: Bool { state.withLock(\.isClosed) }

    func send(_ bytes: [UInt8]) {
        change { $0.echoed.append(bytes) }
    }

    var unsentByteCount: Int { 0 }

    func drain() async throws {}

    func finish() {
        change { $0.isFinished = true }
    }

    func receive() async throws -> [UInt8]? {
        while true {
            let (next, version): ([UInt8]??, Int) = state.withLock { state in
                if state.isClosed { return (.some(nil), state.version) }
                if !state.echoed.isEmpty { return (.some(state.echoed.removeFirst()), state.version) }
                return (state.isFinished ? .some(nil) : nil, state.version)
            }
            if let next { return next }
            await withCheckedContinuation { continuation in
                let hasChanged = state.withLock { state in
                    guard state.version == version else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if hasChanged { continuation.resume() }
            }
        }
    }

    func close() async {
        change { $0.isClosed = true }
    }

    private func change(_ body: (inout State) -> Void) {
        let waiters = state.withLock { state in
            body(&state)
            state.version += 1
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// A TCP client of a port forward on this device's loopback, as another app would be.
final class LoopbackClient: Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ch.shello.tests.client")
    private let hasEnded = Mutex(false)

    private init(connection: NWConnection) {
        self.connection = connection
    }

    deinit {
        connection.forceCancel()
    }

    struct Refused: Error {}

    /// A client connected to `port` of 127.0.0.1.
    /// - Throws: `Refused` when nothing listens there, or nothing answers within five seconds.
    static func connect(port: UInt16) async throws -> LoopbackClient {
        let connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let client = LoopbackClient(connection: connection)
        let isReady: Bool = await withCheckedContinuation { continuation in
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { isReady in
                if once.isFirst() { continuation.resume(returning: isReady) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .waiting, .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: client.queue)
            client.queue.asyncAfter(deadline: .now() + 5) { finish(false) }
        }
        guard isReady else { throw Refused() }
        return client
    }

    /// Whether a client can connect to `port` of 127.0.0.1.
    static func canConnect(port: UInt16) async -> Bool {
        guard let client = try? await connect(port: port) else { return false }
        client.close()
        return true
    }

    /// Whether `port` of 127.0.0.1 refuses connections within two seconds. A listener stops at once,
    /// but the system lets go of its port a moment later (`NWListener.cancel()` is asynchronous): a
    /// connection in that moment still completes, and Shello resets it at once. On a CI runner the
    /// moment was long enough for a check right after closing the tab to connect.
    static func isRefused(port: UInt16) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            if !(await canConnect(port: port)) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return false
    }

    func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    /// The next bytes, or nil once the far side ended its side.
    func receive() async throws -> [UInt8]? {
        // The end can come with the last bytes; the connection then has nothing more to receive.
        guard !hasEnded.withLock({ $0 }) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [self] content, _, isComplete, error in
                if isComplete { hasEnded.withLock { $0 = true } }
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: Array(content))
                } else {
                    continuation.resume(returning: isComplete ? nil : [])
                }
            }
        }
    }

    /// What arrives until it contains `text`, or the far side ends.
    func read(until text: String) async throws -> String {
        var received = ""
        while !received.contains(text), let chunk = try await receive() {
            received += String(decoding: chunk, as: UTF8.self)
        }
        return received
    }

    func close() {
        connection.cancel()
    }
}

/// A port of the loopback that nothing listens on as this is called, which the system chose.
func freeLoopbackPort() async throws -> UInt16 {
    let listener = PortForwardListener(port: 0, target: .socks, open: { _, _ in throw CancellationError() })
    let port = try await listener.start()
    listener.stop()
    await listener.stopped()
    return port
}

/// A TCP server of the test's own on this Mac's loopback, the destination a remote forward reaches
/// from the device: each connection gets `greeting`, then what it sends comes back.
final class EchoServer: Sendable {
    /// The port it listens on, on 127.0.0.1.
    let port: UInt16
    private let listener: NWListener
    private let accepted: Counter

    /// How many connections it accepted, shared with the listener's handler, which a listener needs
    /// before it starts.
    private final class Counter: Sendable {
        let count = Mutex(0)
    }

    init(greeting: String) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = DispatchQueue(label: "ch.shello.tests.echo")
        let accepted = Counter()
        self.accepted = accepted
        listener.newConnectionHandler = { connection in
            accepted.count.withLock { $0 += 1 }
            connection.start(queue: queue)
            connection.send(content: Data(greeting.utf8), completion: .contentProcessed { _ in })
            Self.echo(connection)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.isFirst() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if once.isFirst() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener.cancel()
    }

    /// How many connections it accepted.
    var acceptedCount: Int { accepted.count.withLock { $0 } }

    private static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
            if let content, !content.isEmpty {
                connection.send(content: content, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                connection.send(
                    content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in })
            } else {
                echo(connection)
            }
        }
    }
}

extension ForwardTunnel {
    /// What arrives until it contains `text`, or the far end ends.
    func read(until text: String) async throws -> String {
        var received = ""
        while !received.contains(text), let chunk = try await receive() {
            received += String(decoding: chunk, as: UTF8.self)
        }
        return received
    }
}
