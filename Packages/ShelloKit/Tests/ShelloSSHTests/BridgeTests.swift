import Foundation
import Network
import ShelloModel
import Testing

@testable import ShelloSSH

/// How a connection fails when the other end is not a working SSH server: nothing listens, it says
/// nothing, it hangs up, or it speaks something else. Each end is a listener on this device's
/// loopback, so these tests need no test server.
@Suite(.timeLimit(.minutes(1)))
struct BridgeTests {
    @Test func portNobodyListensOnIsUnreachable() async throws {
        let port = try await FakeServer.closedPort()
        let connection = SSHConnection(
            server: Server(address: "127.0.0.1", port: port), username: "shello", connectTimeout: .seconds(10))

        let error = await #expect(throws: SSHError.self) { try await connection.connect() }

        #expect(error == .unreachable("connection refused"))
    }

    @Test func serverThatSaysNothingTimesOut() async throws {
        let server = try await FakeServer.start { _ in }
        let connection = SSHConnection(
            server: Server(address: "127.0.0.1", port: server.port), username: "shello", connectTimeout: .seconds(1))
        let start = ContinuousClock.now

        await #expect(throws: SSHError.timedOut) { try await connection.connect() }

        #expect(ContinuousClock.now - start < .seconds(5))
        server.stop()
    }

    @Test func serverThatHangsUpEndsTheConnection() async throws {
        let server = try await FakeServer.start { client in
            client.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in client.cancel() })
        }
        let connection = SSHConnection(
            server: Server(address: "127.0.0.1", port: server.port), username: "shello", connectTimeout: .seconds(10))

        let error = await #expect(throws: SSHError.self) { try await connection.connect() }

        // Closed, or reset by the listener's cancel right after.
        guard case .connectionLost = error else {
            Issue.record("Unexpected error \(String(describing: error))")
            return
        }
        server.stop()
    }

    @Test func serverThatSpeaksSomethingElseIsAProtocolError() async throws {
        let server = try await FakeServer.start { client in
            client.send(
                content: Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8), isComplete: true,
                completion: .contentProcessed { _ in client.cancel() })
        }
        let connection = SSHConnection(
            server: Server(address: "127.0.0.1", port: server.port), username: "shello", connectTimeout: .seconds(10))

        let error = await #expect(throws: SSHError.self) { try await connection.connect() }

        switch error {
        case .protocolError, .connectionLost: break
        default: Issue.record("Unexpected error \(String(describing: error))")
        }
        server.stop()
    }

    @Test func connectionWithoutAUserIsRefusedBeforeConnecting() async {
        let connection = SSHConnection(server: Server(address: "127.0.0.1", port: 9), username: "")

        await #expect(throws: SSHError.protocolError("there is no user to sign in as")) {
            try await connection.connect()
        }
    }

    @Test func closingBeforeConnectingFailsTheConnection() async {
        let connection = SSHConnection(server: Server(address: "127.0.0.1", port: 9), username: "shello")
        await connection.close()

        await #expect(throws: SSHError.self) { try await connection.connect() }
    }

    /// A terminal shows why its stream failed through `localizedDescription`: the error's own
    /// sentence, not the system's "The operation couldn't be completed".
    @Test func errorsSayWhatHappenedThroughLocalizedDescription() {
        let error: any Error = SSHError.connectionLost("the server closed the connection")

        #expect(error.localizedDescription == "The connection ended: the server closed the connection.")
    }

    /// Each connection has a serial queue of its own as its executor (STACK section 6).
    @Test func eachConnectionHasAQueueOfItsOwn() async {
        let first = SSHConnection(server: Server(address: "127.0.0.1", port: 9), username: "shello")
        let second = SSHConnection(server: Server(address: "127.0.0.1", port: 9), username: "shello")

        #expect(await first.isOnOwnQueue)
        #expect(await second.isOnOwnQueue)
        #expect(first.queueIdentity != second.queueIdentity)
    }
}

/// What the connection makes of Network.framework's states (TN3179): a first connection that
/// waits fails at once, except while iOS holds it back for Local Network access, which the user may
/// be granting right then. The iOS Simulator has no Local Network access to grant, so the states
/// are given here as a device would report them.
struct NetworkStateTests {
    @Test func waitingForLocalNetworkAccessKeepsWaiting() {
        let change = SSHConnection.change(
            for: .waiting(.posix(.ENETUNREACH)), unsatisfiedReason: .localNetworkDenied, isReady: false)

        #expect(change == .waitingForLocalNetwork)
    }

    /// Refused, no route, no network: waiting for a better path belongs to the tab's reconnecting.
    @Test(arguments: [NWPath.UnsatisfiedReason.notAvailable, .cellularDenied, .wifiDenied, nil])
    func waitingForAnythingElseFailsAFirstConnection(_ reason: NWPath.UnsatisfiedReason?) {
        let change = SSHConnection.change(
            for: .waiting(.posix(.ECONNREFUSED)), unsatisfiedReason: reason, isReady: false)

        #expect(change == .failed(.unreachable("connection refused")))
    }

    @Test func readyConnectionIsReady() {
        #expect(SSHConnection.change(for: .ready, unsatisfiedReason: nil, isReady: false) == .ready)
    }

    @Test func connectionThatFailsAfterBeingReadyIsLost() {
        let change = SSHConnection.change(for: .failed(.posix(.ECONNRESET)), unsatisfiedReason: nil, isReady: true)

        #expect(change == .failed(.connectionLost("connection reset by peer")))
    }

    /// Once iOS gave up waiting for the user, the connection says why it did not connect.
    @Test func deniedLocalNetworkAccessSaysSo() {
        #expect(SSHError.localNetworkDenied.description.contains("Local Network"))
        #expect(SSHError.localNetworkDenied.description.contains("Privacy & Security"))
    }
}

/// A TCP listener on this device's loopback that hands each client to `accept`.
final class FakeServer: Sendable {
    let port: UInt16
    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(accept: @escaping @Sendable (NWConnection) -> Void) async throws -> FakeServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "ch.shello.tests.fake-server")
        listener.newConnectionHandler = { client in
            client.start(queue: queue)
            accept(client)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.isFirst() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.isFirst() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return FakeServer(listener: listener, port: port)
    }

    /// A loopback port that nothing listens on: one a listener had a moment ago. It returns once
    /// the listener has stopped: until then, a connection to the port still reaches it, and is
    /// reset rather than refused.
    static func closedPort() async throws -> UInt16 {
        let server = try await start { _ in }
        await withCheckedContinuation { continuation in
            let once = Once()
            server.listener.stateUpdateHandler = { state in
                if case .cancelled = state, once.isFirst() { continuation.resume() }
            }
            server.stop()
        }
        return server.port
    }

    func stop() {
        listener.cancel()
    }
}
