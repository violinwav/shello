import Foundation
import ShelloModel
import Testing

@testable import ShelloSSH

/// Connections to the test server (TestServers/README.md) through the socketpair bridge: the host
/// key, both ways to sign in, commands on hidden channels, a shell, and two connections at once.
/// Skipped when the server is not running, as on a machine without Docker.
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(1)))
struct ConnectionTests {
    @Test func connectingEndsWithTheServersHostKey() async throws {
        let connection = TestServer.connection()

        let key = try await connection.connect()

        #expect(key == TestServer.hostKeyA)
        #expect(key.fingerprint == "SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY")
        await connection.close()
    }

    /// libssh talks only on its end of the socketpair (ADR 0002): Network.framework made the
    /// connection to the server.
    @Test func libsshTalksOnlyThroughTheSocketpair() async throws {
        let connection = try await TestServer.signedInConnection()

        _ = try await connection.run("true")

        #expect(await connection.libsshUsesTheSocketpair)
        await connection.close()
    }

    @Test(.enabled(if: TestServer.password != nil, TestServer.noPasswords))
    func signsInWithThePassword() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()

        try await connection.authenticate(password: TestSecret(TestServer.password ?? ""))

        #expect(try await connection.run("whoami").outputText == "\(TestServer.user)\n")
        await connection.close()
    }

    @Test func wrongPasswordIsRefused() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()

        await #expect(throws: SSHError.authenticationFailed) {
            try await connection.authenticate(password: TestSecret("not-the-password"))
        }
        await connection.close()
    }

    @Test func signsInWithTheImportedEd25519Key() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()

        try await connection.authenticate(privateKey: TestSecret(TestServer.clientKey))

        #expect(try await connection.run("whoami").outputText == "\(TestServer.user)\n")
        await connection.close()
    }

    @Test func signsInWithAnEncryptedKeyAndItsPassphrase() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()

        try await connection.authenticate(
            privateKey: TestSecret(TestServer.encryptedClientKey), passphrase: TestSecret(TestServer.passphrase))

        #expect(try await connection.run("whoami").outputText == "\(TestServer.user)\n")
        await connection.close()
    }

    /// The spike's command (README section 18): `uname -a` on a hidden channel.
    @Test func runsUnameAndReturnsItsOutput() async throws {
        let connection = try await TestServer.signedInConnection()

        let result = try await connection.run("uname -a")

        let kernel = try await connection.run("uname -s").outputText
        #expect(result.outputText.hasPrefix(kernel.trimmingCharacters(in: .newlines) + " "))
        #expect(result.outputText.hasSuffix("\n"))
        #expect(result.errorOutput.isEmpty)
        #expect(result.exitStatus == 0)
        await connection.close()
    }

    @Test func commandsKeepTheirStandardErrorAndExitStatus() async throws {
        let connection = try await TestServer.signedInConnection()

        let result = try await connection.run("echo out; echo error >&2; exit 3")

        #expect(result.outputText == "out\n")
        #expect(String(decoding: result.errorOutput, as: UTF8.self) == "error\n")
        #expect(result.exitStatus == 3)
        await connection.close()
    }

    /// A command that a signal ends has no exit status.
    @Test func commandEndedByASignalHasNoExitStatus() async throws {
        let connection = try await TestServer.signedInConnection()

        let result = try await connection.run("kill -TERM $$")

        #expect(result.exitStatus == nil)
        await connection.close()
    }

    /// Commands run one after another and at the same time on one connection, each on a channel of
    /// its own.
    @Test func commandsShareAConnection() async throws {
        let connection = try await TestServer.signedInConnection()

        for number in 1...5 {
            #expect(try await connection.run("echo \(number)").outputText == "\(number)\n")
        }
        async let first = connection.run("seq 1 20000")
        async let second = connection.run("seq 20001 40000")
        let outputs = try await [first.outputText, second.outputText]

        #expect(outputs == [Self.numbers(1...20000), Self.numbers(20001...40000)])
        await connection.close()
    }

    /// Each connection runs on its own queue (STACK section 6). Two at once, each with plenty of
    /// output, end with exactly their own output.
    @Test func twoConnectionsAtOnceDoNotInterfere() async throws {
        async let first = Self.signInAndRun("seq 1 100000")
        async let second = Self.signInAndRun("seq 100001 200000")

        let outputs = try await [first, second]

        #expect(outputs == [Self.numbers(1...100_000), Self.numbers(100_001...200_000)])
    }

    /// Ten megabytes through the bridge: many window adjustments, and every byte arrives. The
    /// throughput is printed for the spike's report.
    @Test func tenMegabytesArriveWhole() async throws {
        let connection = try await TestServer.signedInConnection()
        let start = ContinuousClock.now

        let result = try await connection.run("head -c 10485760 /dev/zero | tr '\\0' a")

        let elapsed = ContinuousClock.now - start
        #expect(result.output.count == 10_485_760)
        #expect(result.output.allSatisfy { $0 == UInt8(ascii: "a") })
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(
            "10 MiB on one channel in \(elapsed): \((10 / seconds).formatted(.number.precision(.fractionLength(0)))) MiB/s"
        )
        await connection.close()
    }

    @Test func shellRunsWhatIsTypedAndEndsWithExit() async throws {
        let connection = try await TestServer.signedInConnection()
        let shell = try await connection.openShell(
            terminalType: "xterm-256color", size: TerminalSize(columns: 80, rows: 24))

        shell.send(Array("echo $TERM $((6 * 7))\n".utf8))
        let output = try await shell.output(containing: "xterm-256color 42")
        #expect(output.contains("xterm-256color 42"))

        shell.send(Array("exit\n".utf8))
        var iterator = shell.output.makeAsyncIterator()
        while try await iterator.next() != nil {}
        await connection.close()
    }

    /// A new size reaches the server as a window change, which `stty` reads back.
    @Test func shellTellsTheServerItsNewSize() async throws {
        let connection = try await TestServer.signedInConnection()
        let shell = try await connection.openShell(
            terminalType: "xterm-256color", size: TerminalSize(columns: 80, rows: 24))

        shell.resize(to: TerminalSize(columns: 132, rows: 43))
        shell.send(Array("stty size\n".utf8))

        let output = try await shell.output(containing: "43 132")
        #expect(output.contains("43 132"))
        await connection.close()
    }

    @Test func closingTheConnectionEndsTheShellsOutput() async throws {
        let connection = try await TestServer.signedInConnection()
        let shell = try await connection.openShell(
            terminalType: "xterm-256color", size: TerminalSize(columns: 80, rows: 24))
        shell.send(Array("echo $((40 + 2))\n".utf8))
        _ = try await shell.output(containing: "42")

        await connection.close()

        var iterator = shell.output.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }

    @Test func signingInAgainAfterClosingFails() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()
        await connection.close()

        await #expect(throws: SSHError.closed) {
            try await connection.authenticate(privateKey: TestSecret(TestServer.clientKey))
        }
    }

    /// How long each step takes against the local test server, for the spike's report: printed,
    /// not checked.
    @Test func timesEachStep() async throws {
        let clock = ContinuousClock()
        var connects: [Duration] = []
        var signIns: [Duration] = []
        var commands: [Duration] = []
        var keyExchange: KeyExchange?
        for _ in 0..<10 {
            let connection = TestServer.connection()
            let start = clock.now
            _ = try await connection.connect()
            let connected = clock.now
            try await connection.authenticate(privateKey: TestSecret(TestServer.clientKey))
            let signedIn = clock.now
            _ = try await connection.run("uname -a")
            let ran = clock.now
            keyExchange = await connection.keyExchange
            await connection.close()
            connects.append(connected - start)
            signIns.append(signedIn - connected)
            commands.append(ran - signedIn)
        }
        print(
            """
            Spike timings over 10 connections to \(TestServer.server), key exchange \(keyExchange?.name ?? "?"):
              connect and key exchange: \(Self.summary(connects))
              sign in with the Ed25519 key: \(Self.summary(signIns))
              uname -a on a new channel: \(Self.summary(commands))
            """)
    }

    private static func signInAndRun(_ command: String) async throws -> String {
        let connection = try await TestServer.signedInConnection()
        let output = try await connection.run(command).outputText
        await connection.close()
        return output
    }

    private static func numbers(_ range: ClosedRange<Int>) -> String {
        range.map { "\($0)\n" }.joined()
    }

    private static func summary(_ durations: [Duration]) -> String {
        let sorted = durations.sorted()
        let milliseconds = { (duration: Duration) in
            (Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
                .formatted(.number.precision(.fractionLength(1)))
        }
        return "median \(milliseconds(sorted[sorted.count / 2])) ms, max \(milliseconds(sorted.last ?? .zero)) ms"
    }
}

extension SSHCommandResult {
    var outputText: String { String(decoding: output, as: UTF8.self) }
}
