import Foundation
import Network
import Synchronization

@testable import ShelloSSH

/// A TCP server of the test's own on this Mac's loopback: the destination that a remote forward
/// reaches from the device. Each connection gets what `Behavior` says.
final class DestinationServer: Sendable {
    enum Behavior: Sendable {
        /// Sends `greeting`, then sends back what it receives, and ends its side after the client's.
        case echo(greeting: String)
        /// Sends `count` bytes of `DestinationServer.pattern`, each chunk once the one before was
        /// taken, then ends its side.
        case send(count: Int)
        /// Takes what it receives, counting it, until the client's end, then ends its side.
        case count
    }

    /// The port it listens on, on 127.0.0.1.
    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private let state: Connections

    /// What the server has, shared with its listener's handler, which a listener needs before it
    /// starts.
    private final class Connections: Sendable {
        let state = Mutex((accepted: 0, received: 0, connections: [NWConnection]()))
    }

    init(_ behavior: Behavior) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = DispatchQueue(label: "ch.shello.tests.destination")
        self.queue = queue
        let state = Connections()
        self.state = state
        listener.newConnectionHandler = { connection in Self.serve(connection, behavior, state: state, on: queue) }
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
        stop()
    }

    /// How many connections it accepted.
    var acceptedCount: Int { state.state.withLock(\.accepted) }
    /// How many bytes it took in `.count`.
    var receivedCount: Int { state.state.withLock(\.received) }

    func stop() {
        listener.cancel()
        let connections = state.state.withLock { state in
            defer { state.connections = [] }
            return state.connections
        }
        for connection in connections {
            connection.forceCancel()
        }
    }

    /// The byte at `offset` of what `.send` sends.
    static func pattern(_ offset: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: offset % 251)
    }

    /// The pattern from its start, longer than any chunk by one period, so that any offset's bytes are
    /// one slice of it: a test compares and sends them at memory speed, which byte by byte, in a debug
    /// build, would be slower than the forward it measures.
    static let patternPeriod = (0..<(251 + maximumChunk)).map(pattern)
    static let maximumChunk = 256 * 1024

    /// Whether `bytes` are the pattern from `offset` on.
    static func isPattern(_ bytes: [UInt8], from offset: Int) -> Bool {
        var index = 0
        while index < bytes.count {
            let length = min(maximumChunk, bytes.count - index)
            let start = (offset + index) % 251
            let isEqual = unsafe bytes.withUnsafeBytes { received in
                unsafe patternPeriod.withUnsafeBytes { expected in
                    unsafe memcmp(received.baseAddress! + index, expected.baseAddress! + start, length) == 0
                }
            }
            guard isEqual else { return false }
            index += length
        }
        return true
    }

    private static func serve(
        _ connection: NWConnection, _ behavior: Behavior, state: Connections, on queue: DispatchQueue
    ) {
        state.state.withLock { state in
            state.accepted += 1
            state.connections.append(connection)
        }
        connection.start(queue: queue)
        switch behavior {
        case .echo(let greeting):
            connection.send(content: Data(greeting.utf8), completion: .contentProcessed { _ in })
            echo(connection)
        case .send(let count):
            send(on: connection, from: 0, count: count)
        case .count:
            take(connection, state: state)
        }
    }

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

    private static func send(on connection: NWConnection, from offset: Int, count: Int) {
        guard offset < count else {
            connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            return
        }
        let length = min(64 * 1024, count - offset)
        let chunk = Data(patternPeriod[(offset % 251)..<(offset % 251 + length)])
        connection.send(
            content: chunk,
            completion: .contentProcessed { error in
                guard error == nil else { return }
                send(on: connection, from: offset + length, count: count)
            })
    }

    private static func take(_ connection: NWConnection, state: Connections) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
            if let content { state.state.withLock { $0.received += content.count } }
            if isComplete || error != nil {
                connection.send(
                    content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in })
            } else {
                take(connection, state: state)
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

    /// Everything until the far end ends.
    func readToEnd() async throws -> [UInt8] {
        var received: [UInt8] = []
        while let chunk = try await receive() {
            received += chunk
        }
        return received
    }
}
