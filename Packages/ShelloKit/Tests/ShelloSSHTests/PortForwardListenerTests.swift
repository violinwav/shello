import Foundation
import Synchronization
import Testing

@testable import ShelloSSH

/// A port forward's listener against tunnels whose far end is in the test (`FakeTunnel`), so that no
/// server is needed: it listens on 127.0.0.1 only, a port another listener has fails with its reason,
/// each connection gets a tunnel of its own to the forward's destination, or to the one a SOCKS5
/// client asks for, the bytes and their ends pass both ways, and flow control keeps what Shello holds
/// bounded when either side is slow. `ForwardTests` runs the same against the test servers.
@Suite(.timeLimit(.minutes(1)))
struct PortForwardListenerTests {
    let opener = FakeTunnelOpener()

    // MARK: - Listening

    /// The listener is reached on 127.0.0.1, and on no other address of this device: not the IPv6
    /// loopback, and not the addresses other devices on the network would use (STACK section 7.1).
    @Test func listenerIsReachedOnTheIPv4LoopbackOnly() async throws {
        let listener = PortForwardListener(
            port: 0, target: .destination(address: "localhost", port: 22), open: opener.open)
        let port = try await listener.start()
        defer { listener.stop() }

        #expect(await LoopbackClient.canConnect(to: "127.0.0.1", port: port))
        #expect(!(await LoopbackClient.canConnect(to: "::1", port: port)))
        let addresses = networkAddresses()
        for address in addresses {
            #expect(!(await LoopbackClient.canConnect(to: address, port: port)), "Reached on \(address)")
        }
        print("Listener on 127.0.0.1:\(port), not reached on ::1 nor on \(addresses.joined(separator: ", "))")
    }

    /// A port that another listener has, here another forward's, fails with the reason, and the
    /// first listener carries on.
    @Test func portInUseFailsWithItsReason() async throws {
        let first = PortForwardListener(port: 0, target: .socks, open: opener.open)
        let port = try await first.start()
        defer { first.stop() }
        let second = PortForwardListener(port: port, target: .socks, open: opener.open)

        await #expect(throws: ForwardListenError.portInUse(port)) {
            try await second.start()
        }

        #expect(ForwardListenError.portInUse(port).description == "Port \(port) is in use by another tab or app.")
        #expect(await LoopbackClient.canConnect(port: port))
    }

    /// A listener stopped is no longer reached, and one started again listens on the same port.
    @Test func stoppedListenerIsNotReachedAndTheNextListensAgain() async throws {
        let first = PortForwardListener(port: 0, target: .socks, open: opener.open)
        let port = try await first.start()
        #expect(await LoopbackClient.canConnect(port: port))

        first.stop()
        await first.stopped()

        #expect(first.port == nil)
        #expect(!(await LoopbackClient.canConnect(port: port)))
        let second = PortForwardListener(port: port, target: .socks, open: opener.open)
        #expect(try await second.start() == port)
        #expect(await LoopbackClient.canConnect(port: port))
        second.stop()
    }

    /// Stopping before the listener listens ends its start.
    @Test func stoppedBeforeStartingDoesNotListen() async throws {
        let listener = PortForwardListener(port: 0, target: .socks, open: opener.open)
        listener.stop()

        await #expect(throws: ForwardListenError.stopped) {
            try await listener.start()
        }
    }

    // MARK: - A local forward

    /// Each connection gets a tunnel of its own to the destination; the bytes pass both ways, and
    /// each side's end reaches the other.
    @Test func localForwardPipesEachConnectionThroughATunnelOfItsOwn() async throws {
        let listener = PortForwardListener(
            port: 0, target: .destination(address: "db.internal", port: 5432), open: opener.open)
        let port = try await listener.start()
        defer { listener.stop() }

        let first = try await LoopbackClient.connect(port: port)
        let second = try await LoopbackClient.connect(port: port)
        try await first.send(Array("hello".utf8))
        try await second.send(Array("world".utf8))
        await waitUntil { opener.tunnels.count == 2 && opener.tunnels.allSatisfy { $0.taken.count == 5 } }

        #expect(opener.destinations == ["db.internal:5432", "db.internal:5432"])
        #expect(Set(opener.tunnels.map { String(decoding: $0.taken, as: UTF8.self) }) == ["hello", "world"])
        let tunnel = try #require(opener.tunnels.first { $0.taken == Array("hello".utf8) })
        tunnel.far(send: Array("from the server".utf8))
        #expect(try await first.read(until: "server") == "from the server")

        // The client's end reaches the far end, which may still send; its end closes the client's.
        first.finish()
        await waitUntil { tunnel.isFinished }
        #expect(tunnel.isFinished)
        tunnel.far(send: Array("last".utf8))
        tunnel.farEnd()
        #expect(try await first.readToEnd() == Array("last".utf8))
        await waitUntil { listener.openConnectionCount == 1 }
        #expect(listener.openConnectionCount == 1)
        #expect(listener.acceptedConnectionCount == 2)
        second.close()
    }

    /// A destination the server does not reach closes the client's connection, and says why.
    @Test func unreachableDestinationClosesTheConnectionAndSaysWhy() async throws {
        let activity = Mutex<[PortForwardListener.Activity]>([])
        opener.fail(with: SSHError.channelRefused("Channel opening failure: channel 2 error (2) Connection refused"))
        let listener = PortForwardListener(
            port: 0, target: .destination(address: "db.internal", port: 5432), open: opener.open,
            report: { reported in activity.withLock { $0.append(reported) } })
        let port = try await listener.start()
        defer { listener.stop() }

        let client = try await LoopbackClient.connect(port: port)

        #expect(try await client.readToEnd() == [])
        await waitUntil { !activity.withLock(\.isEmpty) }
        #expect(
            activity.withLock { $0 }
                == [.failed("The server couldn’t connect to db.internal:5432: Connection refused.")])
    }

    /// Stopping the listener ends the connections it accepted, at once.
    @Test func stoppingEndsTheConnections() async throws {
        let listener = PortForwardListener(
            port: 0, target: .destination(address: "localhost", port: 22), open: opener.open)
        let port = try await listener.start()
        let client = try await LoopbackClient.connect(port: port)
        try await client.send([1])
        await waitUntil { opener.tunnels.count == 1 }

        listener.stop()

        await #expect(throws: (any Error).self) {
            _ = try await client.readToEnd()
            throw CancellationError()
        }
        await waitUntil { opener.tunnels.first?.isClosed == true }
        #expect(opener.tunnels.first?.isClosed == true)
        #expect(listener.openConnectionCount == 0)
    }

    // MARK: - A dynamic forward

    /// A SOCKS5 client's destination, an IPv4 address or a domain name, gets the tunnel; the reply
    /// says it is open, and what the client sent after its request goes through.
    @Test(arguments: [("10.0.0.5", "10.0.0.5:80"), ("db.internal", "db.internal:80")])
    func dynamicForwardOpensTheTunnelTheClientAsksFor(_ address: String, _ destination: String) async throws {
        let listener = PortForwardListener(port: 0, target: .socks, open: opener.open)
        let port = try await listener.start()
        defer { listener.stop() }
        let client = try await LoopbackClient.connect(port: port)

        #expect(try await client.socksConnect(to: address, port: 80) == SOCKS5.Reply.succeeded.rawValue)
        try await client.send(Array("GET /".utf8))

        await waitUntil { opener.tunnels.first?.taken.count == 5 }
        #expect(opener.destinations == [destination])
        opener.tunnels.first?.far(send: Array("HTTP/1.1 200".utf8))
        #expect(try await client.read(until: "200") == "HTTP/1.1 200")
        client.close()
    }

    /// The server's refusal reaches the client as SOCKS5's reply for it, and the connection closes.
    @Test func refusedDestinationGetsItsReply() async throws {
        opener.fail(with: SSHError.channelRefused("Channel opening failure: channel 2 error (2) Connection refused"))
        let listener = PortForwardListener(port: 0, target: .socks, open: opener.open)
        let port = try await listener.start()
        defer { listener.stop() }
        let client = try await LoopbackClient.connect(port: port)

        #expect(try await client.socksConnect(to: "127.0.0.1", port: 9) == SOCKS5.Reply.connectionRefused.rawValue)
        #expect(try await client.readToEnd() == [])
    }

    /// A request to bind a port gets "command not supported", and no tunnel opens.
    @Test func bindIsNotSupported() async throws {
        let listener = PortForwardListener(port: 0, target: .socks, open: opener.open)
        let port = try await listener.start()
        defer { listener.stop() }
        let client = try await LoopbackClient.connect(port: port)

        try await client.send([5, 1, 0, 5, 2, 0, 1, 0, 0, 0, 0, 0, 0])

        #expect(try await client.readToEnd() == [5, 0] + SOCKS5.Reply.commandNotSupported.bytes)
        #expect(opener.destinations.isEmpty)
    }

    // MARK: - Flow control

    /// A client that sends 16 MiB as fast as it can, to a far end whose window takes 64 KiB every
    /// millisecond: Shello reads no more from the client while the tunnel holds half a mebibyte, so
    /// it never holds much more, and every byte arrives in order.
    @Test func slowFarEndKeepsWhatShelloHoldsBounded() async throws {
        let opener = FakeTunnelOpener(makeTunnel: { FakeTunnel(window: 64 * 1024, pace: .milliseconds(1)) })
        let listener = PortForwardListener(
            port: 0, target: .destination(address: "localhost", port: 9), open: opener.open)
        let port = try await listener.start()
        defer { listener.stop() }
        let client = try await LoopbackClient.connect(port: port)
        let count = 16 * 1024 * 1024
        let pattern = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7) }

        for start in stride(from: 0, to: count, by: 256 * 1024) {
            try await client.send(Array(pattern[start..<min(count, start + 256 * 1024)]))
        }
        client.finish()
        await waitUntil(timeout: .seconds(30)) { opener.tunnels.first?.isFinished == true }

        let tunnel = try #require(opener.tunnels.first)
        #expect(tunnel.taken == pattern)
        let held = listener.maximumHeldByteCount
        print("16 MiB to a slow far end: Shello held at most \(held) bytes")
        #expect(held <= PortForwardListener.maximumUnsentByteCount + PortForwardListener.chunkSize)
    }

    /// A far end that sends 16 MiB as fast as it is read, to a client that reads slowly: Shello reads
    /// the next chunk from the tunnel only once the client's connection took the one before, so it
    /// holds one chunk at most, and the far end produces only a little ahead of the client.
    @Test func slowClientKeepsWhatShelloHoldsBounded() async throws {
        let listener = PortForwardListener(
            port: 0, target: .destination(address: "localhost", port: 9), open: opener.open)
        let port = try await listener.start()
        defer { listener.stop() }
        let client = try await LoopbackClient.connect(port: port)
        try await client.send([0])
        await waitUntil { opener.tunnels.count == 1 }
        let tunnel = try #require(opener.tunnels.first)
        let count = 16 * 1024 * 1024
        tunnel.produce(count)

        // The client pauses after its first mebibyte: the far end stops soon after.
        _ = try await client.read(count: 1024 * 1024)
        try await Task.sleep(for: .milliseconds(500))
        let producedWhilePaused = tunnel.produced
        try await Task.sleep(for: .milliseconds(500))
        #expect(tunnel.produced == producedWhilePaused)
        var received = 1024 * 1024
        var isInOrder = true
        while let chunk = try await client.receive() {
            for (offset, byte) in chunk.enumerated() where byte != UInt8(truncatingIfNeeded: received + offset) {
                isInOrder = false
            }
            received += chunk.count
        }

        #expect(received == count)
        #expect(isInOrder)
        let held = listener.maximumHeldByteCount
        print(
            "16 MiB to a slow client: the far end ran \(producedWhilePaused - 1024 * 1024) bytes ahead of it while "
                + "it paused, and Shello held at most \(held) bytes")
        #expect(held <= PortForwardListener.chunkSize)
    }
}

/// Waits until `condition` holds, for at most `timeout`, checking every few milliseconds.
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
