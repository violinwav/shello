import Foundation
import ShelloModel
import Testing

@testable import ShelloSSH

/// The keepalive (README section 4) against the test server: OpenSSH's `keepalive@openssh.com`, a
/// request the server answers, whose round trip a tab shows as its latency. Skipped when the server
/// is not running.
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(1)))
struct KeepaliveTests {
    /// The server does not know the request and answers with a failure, which counts as an answer:
    /// the connection is alive. Each keepalive gets its own answer, and the connection goes on.
    @Test func keepaliveComesBackWithItsRoundTrip() async throws {
        let connection = try await TestServer.signedInConnection()

        let first = try await connection.keepalive()
        let second = try await connection.keepalive()

        #expect(first > .zero && first < .seconds(5))
        #expect(second > .zero && second < .seconds(5))
        #expect(try await connection.run("echo alive").outputText == "alive\n")
        await connection.close()
    }

    /// A keepalive while the shell prints still comes back, and the output arrives whole.
    @Test func keepaliveWhileTheShellPrints() async throws {
        let connection = try await TestServer.signedInConnection()
        let shell = try await connection.openShell(
            terminalType: "xterm-256color", size: TerminalSize(columns: 80, rows: 24))
        // The marker line takes whatever the shell puts before the output on its line.
        shell.send(Array("echo numbers; seq 1 20000; echo done-$((6 * 7))\n".utf8))

        async let output = shell.output(containing: "done-42")
        let roundTrip = try await connection.keepalive()

        #expect(roundTrip > .zero)
        let numbers = try await output.split(whereSeparator: \.isNewline).compactMap { Int($0) }
        #expect(numbers == Array(1...20000))
        await connection.close()
    }

    @Test func keepaliveOnAClosedConnectionFails() async throws {
        let connection = try await TestServer.signedInConnection()
        await connection.close()

        await #expect(throws: SSHError.closed) {
            try await connection.keepalive()
        }
    }
}
