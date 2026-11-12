import Foundation
import ShelloModel
import Testing

@testable import ShelloSSH

/// Tunnels (`SSHTunnel`), the `direct-tcpip` channels that the hops of a route run over (README
/// section 3), against the test servers (TestServers/README.md): the bytes of the port they reach in
/// both directions, their end in both directions, a refusal, and connections through one and two
/// jump hosts, which keep SSH's flow control and end when the jump host's connection does. In
/// Docker, the server on port 2222 reaches the others by name on the servers' network; this Mac's
/// sshd reaches them on the loopback. Skipped when the servers are not running.
@Suite(
    .serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning },
    .enabled(TestServer.jumpServersNotRunning) { await TestServer.areJumpServersRunning },
    .timeLimit(.minutes(2)))
struct TunnelTests {
    // MARK: - The tunnel

    /// The tunnel carries what the far end sends, here the SSH banner of the server's own port, and
    /// what Shello sends: a line that is no SSH banner, after which the server hangs up, which ends
    /// the tunnel's output.
    @Test func tunnelCarriesBothWaysAndEndsWithTheFarEnd() async throws {
        let connection = try await TestServer.signedInConnection()
        let tunnel = try await connection.openTunnel(to: TestServer.ownPort.address, port: TestServer.ownPort.port)

        let banner = try await Self.read(tunnel, until: "\r\n")
        #expect(banner.hasPrefix("SSH-2.0-OpenSSH_"))
        tunnel.send(Array("not an SSH client\r\n".utf8))
        try await tunnel.drain()
        #expect(tunnel.unsentByteCount == 0)

        var iterator = tunnel.output.makeAsyncIterator()
        while try await iterator.next() != nil {}
        await connection.close()
    }

    /// Finishing ends what Shello sends: the server reads the end before any banner, and hangs up.
    @Test func finishingEndsWhatShelloSends() async throws {
        let connection = try await TestServer.signedInConnection()
        let tunnel = try await connection.openTunnel(to: TestServer.ownPort.address, port: TestServer.ownPort.port)
        _ = try await Self.read(tunnel, until: "\r\n")

        tunnel.finish()

        while try await tunnel.receive() != nil {}
        // The connection carries on.
        #expect(try await connection.run("echo still-$((40 + 2))").outputText == "still-42\n")
        await connection.close()
    }

    /// Closing the tunnel ends its output at once; the connection carries on.
    @Test func closingTheTunnelEndsItsOutput() async throws {
        let connection = try await TestServer.signedInConnection()
        let tunnel = try await connection.openTunnel(to: TestServer.ownPort.address, port: TestServer.ownPort.port)

        await tunnel.close()

        #expect(try await tunnel.receive() == nil)
        #expect(try await connection.run("true").exitStatus == 0)
        await connection.close()
    }

    /// The server says why it opened no tunnel: here, nothing listens on the port.
    @Test func tunnelToAPortNobodyListensOnIsRefused() async throws {
        let connection = try await TestServer.signedInConnection()

        let error = await #expect(throws: SSHError.self) {
            try await connection.openTunnel(to: "127.0.0.1", port: 9)
        }

        guard case .channelRefused(let message) = error else {
            Issue.record("Unexpected error \(String(describing: error))")
            await connection.close()
            return
        }
        #expect(SSHConnection.openFailureReason(message) == "Connection refused")
        await connection.close()
    }

    /// libssh's message ends with the server's reason, after the channel and the reason's code.
    @Test func openFailureReasonIsTheServersOwn() {
        #expect(
            SSHConnection.openFailureReason("Channel opening failure: channel 43 error (2) Connection refused")
                == "Connection refused")
        #expect(
            SSHConnection.openFailureReason("Channel opening failure: channel 0 error (1) open failed")
                == "open failed")
        #expect(SSHConnection.openFailureReason("Remote channel is closed") == "Remote channel is closed")
        #expect(
            SSHConnection.openFailureReason("Channel opening failure: channel 1 error (2) ")
                == "Channel opening failure: channel 1 error (2) ")
    }

    // MARK: - Connections through jump hosts

    /// The next hop's connection: its own host key, sign-in and commands, with libssh on its own
    /// socketpair and its own queue (ADR 0002).
    @Test func connectionThroughAJumpHostSignsInAndRuns() async throws {
        let jumpHost = try await TestServer.signedInConnection()
        let connection = SSHConnection(
            server: TestServer.reachedFromAnother(port: 2224), username: TestServer.user,
            connectTimeout: TestServer.connectTimeout, through: jumpHost)

        #expect(try await connection.connect() == TestServer.hostKeyA)
        try await connection.authenticate(privateKey: TestSecret(TestServer.clientKey))

        #expect(try await connection.run("whoami").outputText == "\(TestServer.user)\n")
        #expect(await connection.libsshUsesTheSocketpair)
        #expect(await connection.isOnOwnQueue)
        #expect(connection.queueIdentity != jumpHost.queueIdentity)
        // OpenSSH 10 without post-quantum key exchange, behind OpenSSH 10 with it: each hop has its
        // own key exchange.
        #expect(await connection.keyExchange?.isPostQuantum == false)
        #expect(await jumpHost.keyExchange?.isPostQuantum == true)
        await connection.close()
        await jumpHost.close()
    }

    @Test func connectionThroughTwoJumpHostsSignsInAndRuns() async throws {
        let first = try await TestServer.signedInConnection()
        let second = try await Self.signedInConnection(to: TestServer.reachedFromAnother(port: 2224), through: first)
        let third = try await Self.signedInConnection(to: TestServer.reachedFromAnother(port: 2226), through: second)

        #expect(try await third.run("whoami").outputText == "\(TestServer.user)\n")
        #expect(await third.keyExchange?.name == "ecdh-sha2-nistp256")

        for connection in [third, second, first] {
            await connection.close()
        }
    }

    /// Ten megabytes from the server two connections deep: many window adjustments on both channels
    /// on the way, and every byte arrives. The throughput is printed.
    @Test func tenMegabytesThroughAJumpHostArriveWhole() async throws {
        let jumpHost = try await TestServer.signedInConnection()
        let connection = try await Self.signedInConnection(
            to: TestServer.reachedFromAnother(port: 2224), through: jumpHost)
        let start = ContinuousClock.now

        let result = try await connection.run("head -c 10485760 /dev/zero | tr '\\0' a")

        let elapsed = ContinuousClock.now - start
        #expect(result.output.count == 10_485_760)
        #expect(result.output.allSatisfy { $0 == UInt8(ascii: "a") })
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            "10 MiB through a jump host in \(elapsed): "
                + "\((10 / seconds).formatted(.number.precision(.fractionLength(0)))) MiB/s")
        await connection.close()
        await jumpHost.close()
    }

    /// Four megabytes typed into a shell two connections deep, more than both channels' windows
    /// take at once: the bytes wait for each window, and all of them arrive.
    @Test func whatAShellSendsThroughAJumpHostArrivesWhole() async throws {
        let jumpHost = try await TestServer.signedInConnection()
        let connection = try await Self.signedInConnection(
            to: TestServer.reachedFromAnother(port: 2224), through: jumpHost)
        let shell = try await connection.openShell(
            terminalType: "xterm-256color", size: TerminalSize(columns: 80, rows: 24))
        var output = shell.output.makeAsyncIterator()
        // Raw and without echo, so that the terminal passes every byte on as it is.
        shell.send(Array("stty raw -echo; echo read-$((2 * 2)); head -c 4194304 | wc -c\r".utf8))
        _ = try await Self.read(&output, until: "read-4")

        shell.send([UInt8](repeating: UInt8(ascii: "a"), count: 4_194_304))

        #expect(try await Self.read(&output, until: "4194304").contains("4194304"))
        await connection.close()
        await jumpHost.close()
    }

    /// A jump host whose connection ends ends the connection through it, as lost: a tab then sees
    /// one failure and reconnects the whole route.
    @Test func closingTheJumpHostEndsTheConnectionThroughIt() async throws {
        let jumpHost = try await TestServer.signedInConnection()
        let connection = try await Self.signedInConnection(
            to: TestServer.reachedFromAnother(port: 2224), through: jumpHost)
        let shell = try await connection.openShell(
            terminalType: "xterm-256color", size: TerminalSize(columns: 80, rows: 24))

        await jumpHost.close()

        await #expect(throws: SSHError.connectionLost("the jump host’s connection was closed")) {
            var output = shell.output.makeAsyncIterator()
            while try await output.next() != nil {}
        }
        await #expect(throws: SSHError.connectionLost("the jump host’s connection was closed")) {
            try await connection.run("true")
        }
        await connection.close()
    }

    /// A server the jump host cannot reach is unreachable, as one the device cannot reach is.
    @Test func serverTheJumpHostCannotReachIsUnreachable() async throws {
        let jumpHost = try await TestServer.signedInConnection()
        let connection = SSHConnection(
            server: Server(address: "127.0.0.1", port: 9), username: TestServer.user,
            connectTimeout: TestServer.connectTimeout, through: jumpHost)

        await #expect(throws: SSHError.unreachable("the jump host couldn’t connect to it (Connection refused)")) {
            try await connection.connect()
        }
        // The jump host's connection carries on.
        #expect(try await jumpHost.run("true").exitStatus == 0)
        await jumpHost.close()
    }

    // MARK: - Helpers

    /// A connection to `server` through `jumpHost`, signed in with the fixture key.
    private static func signedInConnection(to server: Server, through jumpHost: SSHConnection) async throws
        -> SSHConnection
    {
        let connection = SSHConnection(
            server: server, username: TestServer.user, connectTimeout: TestServer.connectTimeout, through: jumpHost)
        _ = try await connection.connect()
        try await connection.authenticate(privateKey: TestSecret(TestServer.clientKey))
        return connection
    }

    /// What the tunnel sends until it has sent `text`.
    private static func read(_ tunnel: SSHTunnel, until text: String) async throws -> String {
        var received = ""
        while !received.contains(text), let chunk = try await tunnel.receive() {
            received += String(decoding: chunk, as: UTF8.self)
        }
        return received
    }

    /// What the shell prints until it has printed `text`.
    private static func read(_ output: inout SSHShell.Output.Iterator, until text: String) async throws -> String {
        var received = ""
        while !received.contains(text), let chunk = try await output.next() {
            received += String(decoding: chunk, as: UTF8.self)
        }
        return received
    }
}
