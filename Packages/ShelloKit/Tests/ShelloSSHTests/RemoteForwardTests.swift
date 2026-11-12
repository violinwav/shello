import Foundation
import ShelloModel
import Synchronization
import Testing

@testable import ShelloSSH

/// Remote forwards (README section 4) over a connection to the test server on port 2222
/// (TestServers/README.md): the server listens on a port of its own, and each connection to it
/// comes back to a listener this test runs on the Mac, as the device reaches it. A second connection
/// to the server reaches that port from the server, over a tunnel of its own, as a program on the
/// server would. A refused request, a port in use and a destination that does not answer each fail
/// alone; a cancel stops the server's listening; fifty megabytes arrive whole through one while the
/// memory stays flat. Skipped when the server is not running.
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(3)))
struct RemoteForwardTests {
    /// A connection the server forwards reaches the destination, both ways, and ends both ways; once
    /// the forward stops, the server's port refuses connections.
    @Test func remoteForwardReachesAListenerOnTheMac() async throws {
        let destination = try await DestinationServer(.echo(greeting: "hello from the Mac\n"))
        let connection = try await TestServer.signedInConnection()
        let port = try await freeLoopbackPort()
        let forward = Self.forward(port, to: destination.port, over: connection)

        #expect(try await forward.start() == port)

        let reach = try await TestServer.signedInConnection()
        let tunnel = try await reach.openTunnel(to: "127.0.0.1", port: port)
        #expect(try await tunnel.read(until: "\n") == "hello from the Mac\n")
        tunnel.send(Array("ping\n".utf8))
        #expect(try await tunnel.read(until: "\n") == "ping\n")
        tunnel.finish()
        #expect(try await tunnel.readToEnd() == [])
        #expect(destination.acceptedCount == 1)
        #expect(forward.acceptedConnectionCount == 1)

        forward.stop()
        await forward.stopped()
        await #expect(throws: SSHError.self) { try await reach.openTunnel(to: "127.0.0.1", port: port) }
        await reach.close()
        await connection.close()
    }

    /// libssh keeps one global request at a time: a remote forward asked for while a keepalive waits
    /// for its answer is sent once that answer came, rather than given the keepalive's.
    @Test func remoteForwardAskedForDuringAKeepaliveIsSent() async throws {
        let destination = try await DestinationServer(.echo(greeting: "after the keepalive\n"))
        let connection = try await TestServer.signedInConnection()
        let port = try await freeLoopbackPort()
        let forward = Self.forward(port, to: destination.port, over: connection)

        let keepalive = Task { try await connection.keepalive() }
        let started = try await forward.start()
        _ = try await keepalive.value

        #expect(started == port)
        let reach = try await TestServer.signedInConnection()
        let tunnel = try await reach.openTunnel(to: "127.0.0.1", port: port)
        #expect(try await tunnel.read(until: "\n") == "after the keepalive\n")
        await tunnel.close()
        forward.stop()
        await reach.close()
        await connection.close()
    }

    /// A port another connection's remote forward has is refused, with what the server answered; the
    /// connection and the other forward go on.
    @Test func portInUseFailsThatForwardOnly() async throws {
        let destination = try await DestinationServer(.echo(greeting: "first\n"))
        let first = try await TestServer.signedInConnection()
        let second = try await TestServer.signedInConnection()
        let port = try await freeLoopbackPort()
        let taken = Self.forward(port, to: destination.port, over: first)
        try await taken.start()

        let refused = Self.forward(port, to: destination.port, over: second)
        await #expect(throws: ForwardListenError.serverRefused(port)) { try await refused.start() }

        _ = try await second.keepalive()
        let tunnel = try await second.openTunnel(to: "127.0.0.1", port: port)
        #expect(try await tunnel.read(until: "\n") == "first\n")
        await tunnel.close()
        taken.stop()
        await first.close()
        await second.close()
    }

    /// A port below 1024 needs the server's administrator: OpenSSH refuses it to the test user, and
    /// says only that it did not listen.
    @Test func privilegedPortIsRefused() async throws {
        let connection = try await TestServer.signedInConnection()
        let forward = Self.forward(22, to: 9, over: connection)

        await #expect(throws: ForwardListenError.serverRefused(22)) { try await forward.start() }

        #expect(
            ForwardListenError.serverRefused(22).description
                == "The server refused to listen on its port 22. It may not allow remote forwards, or the port may be "
                + "in use or reserved.")
        _ = try await connection.keepalive()
        await connection.close()
    }

    /// A server that allows local forwards only (`AllowTcpForwarding local`, the test server on
    /// port 2226) refuses a remote forward, and still opens tunnels.
    @Test func serverThatAllowsLocalForwardsOnlyRefusesARemoteOne() async throws {
        try #require(await TestServer.hasSSHBanner(port: 2226), "The test server on 2226 is not running")
        let connection = SSHConnection(
            server: Server(address: TestServer.address, port: 2226), username: TestServer.user,
            connectTimeout: TestServer.connectTimeout)
        _ = try await connection.connect()
        try await connection.authenticate(privateKey: TestSecret(TestServer.clientKey))
        let port = try await freeLoopbackPort()
        let forward = Self.forward(port, to: 9, over: connection)

        await #expect(throws: ForwardListenError.serverRefused(port)) { try await forward.start() }

        let ownPort: UInt16 = TestServer.isThisMacsSSHD ? 2226 : 22
        let tunnel = try await connection.openTunnel(
            to: TestServer.isThisMacsSSHD ? "127.0.0.1" : "localhost", port: ownPort)
        #expect(try await tunnel.read(until: "\r\n").hasPrefix("SSH-2.0-OpenSSH_"))
        await tunnel.close()
        await connection.close()
    }

    /// A destination that does not answer closes that one connection: the client on the server's
    /// side reads the end, the forward says why, and the next connection reaches a destination that
    /// answers again.
    @Test func destinationThatDoesNotAnswerClosesThatConnectionOnly() async throws {
        let nothing = try await freeLoopbackPort()
        let connection = try await TestServer.signedInConnection()
        let port = try await freeLoopbackPort()
        let reports = Mutex<[PortForwardListener.Activity]>([])
        let forward = RemoteForwardListener(
            port: port, bindAddress: "", destination: ForwardDestination(address: "127.0.0.1", port: nothing),
            over: connection, report: { activity in reports.withLock { $0.append(activity) } })
        try await forward.start()
        let reach = try await TestServer.signedInConnection()

        let tunnel = try await reach.openTunnel(to: "127.0.0.1", port: port)

        #expect(try await tunnel.readToEnd() == [])
        let deadline = ContinuousClock.now + .seconds(5)
        while reports.withLock(\.isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            reports.withLock { $0 }
                == [.failed("Shello couldn’t connect to 127.0.0.1:\(nothing): Connection refused.")])
        #expect(forward.isListening)
        _ = try await connection.keepalive()
        await tunnel.close()
        forward.stop()
        await reach.close()
        await connection.close()
    }

    /// Fifty megabytes from the listener on the Mac, through a remote forward, to a client on the
    /// server: every byte arrives in order, while the process's memory stays flat, as does what the
    /// forward holds for the connection. The figures are printed for the issue.
    @Test func fiftyMegabytesThroughARemoteForwardArriveWholeWithFlatMemory() async throws {
        let count = 50 * 1024 * 1024
        let destination = try await DestinationServer(.send(count: count))
        let connection = try await TestServer.signedInConnection()
        let port = try await freeLoopbackPort()
        let forward = Self.forward(port, to: destination.port, over: connection)
        try await forward.start()
        let reach = try await TestServer.signedInConnection()
        let tunnel = try await reach.openTunnel(to: "127.0.0.1", port: port)

        let baseline = MemoryFootprint.current
        let start = ContinuousClock.now
        var received = 0
        var isInOrder = true
        var peak = baseline
        var nextSample = 0
        while let chunk = try await tunnel.receive() {
            isInOrder = DestinationServer.isPattern(chunk, from: received)
            received += chunk.count
            if received >= nextSample {
                peak = max(peak, MemoryFootprint.current)
                nextSample += 1024 * 1024
            }
            guard isInOrder else { break }
        }
        let elapsed = ContinuousClock.now - start
        let after = MemoryFootprint.current

        #expect(isInOrder)
        #expect(received == count)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let mebibyte = 1024.0 * 1024
        func mebibytes(_ bytes: Int) -> String {
            (Double(bytes) / mebibyte).formatted(.number.precision(.fractionLength(1)))
        }
        print(
            "50 MiB through a remote forward: \(received) bytes in order in "
                + "\(seconds.formatted(.number.precision(.fractionLength(1)))) s, "
                + "\((Double(received) / mebibyte / seconds).formatted(.number.precision(.fractionLength(1)))) MiB/s; "
                + "memory footprint \(mebibytes(baseline)) MiB before, peak \(mebibytes(peak)) MiB "
                + "(+\(mebibytes(peak - baseline)) MiB), \(mebibytes(after)) MiB after; "
                + "the forward held at most \(forward.maximumHeldByteCount) bytes for the connection")
        // Flat: the 50 MiB never pile up anywhere. What libssh, the channels' windows and the sockets
        // hold on the way is a few mebibytes.
        #expect(peak - baseline < 16 * 1024 * 1024)
        #expect(
            forward.maximumHeldByteCount <= PortForwardListener.maximumUnsentByteCount + PortForwardListener.chunkSize)
        await tunnel.close()
        forward.stop()
        await reach.close()
        await connection.close()
    }

    /// Closing the connection ends the server's listening with it, and the forward's channels.
    @Test func closingTheConnectionEndsTheForward() async throws {
        let destination = try await DestinationServer(.echo(greeting: "hello\n"))
        let connection = try await TestServer.signedInConnection()
        let port = try await freeLoopbackPort()
        let reports = Mutex<[PortForwardListener.Activity]>([])
        let forward = RemoteForwardListener(
            port: port, bindAddress: "", destination: ForwardDestination(address: "127.0.0.1", port: destination.port),
            over: connection, report: { activity in reports.withLock { $0.append(activity) } })
        try await forward.start()

        await connection.close()

        let deadline = ContinuousClock.now + .seconds(5)
        while reports.withLock(\.isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reports.withLock { $0 } == [.stoppedListening("The connection ended.")])
        #expect(!forward.isListening)
        let reach = try await TestServer.signedInConnection()
        var isRefused = false
        while !isRefused, ContinuousClock.now < deadline + .seconds(5) {
            do {
                let tunnel = try await reach.openTunnel(to: "127.0.0.1", port: port)
                await tunnel.close()
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                isRefused = true
            }
        }
        #expect(isRefused)
        await reach.close()
    }

    // MARK: - Helpers

    /// A remote forward from the server's `port` on its loopback to `destination` on this Mac's.
    private static func forward(
        _ port: UInt16, to destination: UInt16, over connection: SSHConnection
    ) -> RemoteForwardListener {
        RemoteForwardListener(
            port: port, bindAddress: "", destination: ForwardDestination(address: "127.0.0.1", port: destination),
            over: connection)
    }
}

/// `RemoteForwardListener` on stand-ins for the connection and its channels, without a server: what
/// goes to the server, how it ends, and flow control.
@Suite(.timeLimit(.minutes(1)))
struct RemoteForwardListenerTests {
    /// OpenSSH's client sends `localhost` for no bind address, and an empty one for `*`.
    @Test(arguments: [("", "localhost"), ("*", ""), ("0.0.0.0", "0.0.0.0"), ("::1", "::1")])
    func bindAddressGoesToTheServerAsOpenSSHSendsIt(_ bindAddress: String, _ requested: String) async throws {
        let forwarding = FakeRemoteForwarding()
        let forward = RemoteForwardListener(
            port: 8080, bindAddress: bindAddress, destination: ForwardDestination(address: "127.0.0.1", port: 9),
            over: forwarding)

        try await forward.start()
        forward.stop()
        await forward.stopped()

        #expect(forwarding.requests == ["\(requested):8080"])
        #expect(forwarding.cancels == ["\(requested):8080"])
    }

    /// A stop before the server answered still cancels, and the start says it stopped.
    @Test func stopBeforeTheAnswerCancels() async throws {
        let forwarding = FakeRemoteForwarding(answersAfter: .milliseconds(200))
        let forward = RemoteForwardListener(
            port: 8080, bindAddress: "", destination: ForwardDestination(address: "127.0.0.1", port: 9),
            over: forwarding)

        let start = Task { try await forward.start() }
        try await Task.sleep(for: .milliseconds(50))
        forward.stop()
        await forward.stopped()

        await #expect(throws: ForwardListenError.stopped) { try await start.value }
        #expect(forwarding.cancels == ["localhost:8080"])
    }

    /// Sixteen mebibytes from a destination that sends as fast as it can, to a far end that takes
    /// 64 KiB every millisecond: the forward reads no more from the destination while the channel
    /// holds 512 KiB, and so holds at most that plus one chunk.
    @Test func fastDestinationIsHeldBackByTheChannel() async throws {
        let count = 16 * 1024 * 1024
        let destination = try await DestinationServer(.send(count: count))
        let forwarding = FakeRemoteForwarding()
        let forward = RemoteForwardListener(
            port: 8080, bindAddress: "", destination: ForwardDestination(address: "127.0.0.1", port: destination.port),
            over: forwarding)
        try await forward.start()
        let channel = FakeTunnel(window: 64 * 1024, pace: .milliseconds(1))

        forwarding.forward(channel)

        let deadline = ContinuousClock.now + .seconds(30)
        while !channel.isFinished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(channel.isFinished)
        #expect(channel.taken.count == count)
        #expect(DestinationServer.isPattern(channel.taken, from: 0))
        #expect(
            forward.maximumHeldByteCount <= PortForwardListener.maximumUnsentByteCount + PortForwardListener.chunkSize)
        forward.stop()
    }

    /// What the server's client sends reaches the destination, and its end too.
    @Test func whatTheServersClientSendsReachesTheDestination() async throws {
        let destination = try await DestinationServer(.count)
        let forwarding = FakeRemoteForwarding()
        let forward = RemoteForwardListener(
            port: 8080, bindAddress: "", destination: ForwardDestination(address: "127.0.0.1", port: destination.port),
            over: forwarding)
        try await forward.start()
        let channel = FakeTunnel()
        channel.produce(4 * 1024 * 1024)

        forwarding.forward(channel)

        let deadline = ContinuousClock.now + .seconds(30)
        while !channel.isFinished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(destination.receivedCount == 4 * 1024 * 1024)
        #expect(channel.isFinished)
        forward.stop()
    }
}

/// A connection whose server takes every remote forward, at once or after `answersAfter`, and
/// forwards the channels the test gives it to the last forward asked for.
final class FakeRemoteForwarding: RemoteForwarding {
    private let answersAfter: Duration?
    private let state = Mutex(
        (requests: [String](), cancels: [String](), continuation: AsyncStream<any ForwardTunnel>.Continuation?.none))

    init(answersAfter: Duration? = nil) {
        self.answersAfter = answersAfter
    }

    var requests: [String] { state.withLock(\.requests) }
    var cancels: [String] { state.withLock(\.cancels) }

    func requestRemoteForward(bindAddress: String, port: UInt16) async throws -> AsyncStream<any ForwardTunnel> {
        state.withLock { $0.requests.append("\(bindAddress):\(port)") }
        if let answersAfter {
            try? await Task.sleep(for: answersAfter)
        }
        let (channels, continuation) = AsyncStream.makeStream(of: (any ForwardTunnel).self)
        state.withLock { $0.continuation = continuation }
        return channels
    }

    func cancelRemoteForward(bindAddress: String, port: UInt16) async {
        let continuation = state.withLock { state in
            state.cancels.append("\(bindAddress):\(port)")
            return state.continuation
        }
        continuation?.finish()
    }

    /// The server forwards a connection through `channel`.
    func forward(_ channel: any ForwardTunnel) {
        state.withLock(\.continuation)?.yield(channel)
    }
}
