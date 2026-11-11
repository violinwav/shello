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
