import ShelloModel
import ShelloSSH
import Synchronization
import Testing

@testable import ShelloTmux

/// The version check on a hidden channel that decides whether a connection attaches a tmux session
/// (README section 8), the command that attaches it, and the note a plain shell gets, over a
/// stand-in for the connection's hidden channels.
struct TmuxCheckTests {
    @Test func tmux18OrLaterIsAvailable() async throws {
        let channels = FakeChannels(.printed("tmux 3.4\n"))

        let check = try await Tmux.check(on: channels)

        #expect(check == .available(try #require(TmuxVersion(name: "3.4"))))
        #expect(channels.commands == ["tmux -V"])
    }

    /// Shells exit with 127 for a command they did not find: sh, bash, zsh and fish alike.
    @Test func commandTheShellDidNotFindIsMissing() async throws {
        let channels = FakeChannels(.failed(127, "bash: line 1: tmux: command not found\n"))

        #expect(try await Tmux.check(on: channels) == .missing)
    }

    @Test func tmuxOlderThan18IsTooOld() async throws {
        let channels = FakeChannels(.printed("tmux 1.6\n"))

        #expect(try await Tmux.check(on: channels) == .tooOld(try #require(TmuxVersion(name: "1.6"))))
    }

    /// tmux before 1.2 or so has no `-V`, and prints its usage; csh says "Command not found." with
    /// status 1. Shello cannot tell, and says what it heard.
    @Test(arguments: [
        (
            FakeChannels.Answer.failed(1, "usage: tmux [-28lquv] [-c shell-command]\n"),
            "usage: tmux [-28lquv] [-c shell-command]"
        ),
        (.failed(1, "tmux: Command not found.\n"), "tmux: Command not found."),
        (.printed("tmux unknown-build\n"), "tmux unknown-build"),
        (.printed(""), "tmux -V exited with status 0"),
        (.result(SSHCommandResult(output: [], errorOutput: [], exitStatus: nil)), "tmux -V ended without a status"),
        (
            .throwing(SSHError.channelRefused("administratively prohibited")),
            "The server refused the request: administratively prohibited."
        ),
    ])
    func whatShelloCannotTellIsUnknown(_ answer: FakeChannels.Answer, detail: String) async throws {
        #expect(try await Tmux.check(on: FakeChannels(answer)) == .unknown(detail))
    }

    /// A connection that is gone ends the session's start, and the tab reconnects.
    @Test(arguments: [SSHError.connectionLost("the network dropped the connection"), .closed])
    func lostConnectionIsThrown(_ error: SSHError) async {
        await #expect(throws: error) {
            try await Tmux.check(on: FakeChannels(.throwing(error)))
        }
    }

    @Test func cancellationIsThrown() async {
        await #expect(throws: CancellationError.self) {
            try await Tmux.check(on: FakeChannels(.throwing(CancellationError())))
        }
    }

    // MARK: - Attaching

    @Test func availableTmuxAttachesTheSession() async throws {
        let attachment = try await Tmux.attachment(sessionName: "main", on: FakeChannels(.printed("tmux 3.7c\n")))

        #expect(
            attachment == .attaching(try #require(TmuxSessionName("main")), try #require(TmuxVersion(name: "3.7c"))))
    }

    @Test func missingTmuxRunsAPlainShell() async throws {
        let attachment = try await Tmux.attachment(sessionName: "main", on: FakeChannels(.failed(127, "")))

        #expect(attachment == .plainShell(.missing))
    }

    /// A name that is no `TmuxSessionName` is never typed, nor is tmux asked.
    @Test func invalidSessionNameRunsAPlainShellWithoutAsking() async throws {
        let channels = FakeChannels(.printed("tmux 3.4\n"))

        let attachment = try await Tmux.attachment(sessionName: "a'b; reboot", on: channels)

        #expect(attachment == .plainShell(.invalidSessionName("a'b; reboot")))
        #expect(channels.commands.isEmpty)
    }

    /// `tmux new -A -s main`, with the name quoted, and UTF-8, which Shello's terminal speaks.
    @Test func attachCommandIsNewSessionWithAttachAndTheQuotedName() throws {
        let command = Tmux.attachCommand(for: try #require(TmuxSessionName("deploy-1")))

        #expect(command == "tmux -u new-session -A -s 'deploy-1'")
    }

    @Test(arguments: [("main", "'main'"), ("it's", #"'it'\''s'"#), ("", "''"), ("$(id) `id`", "'$(id) `id`'")])
    func quotingKeepsTheTextFromTheShell(_ text: String, quoted: String) {
        #expect(Tmux.shellQuoted(text) == quoted)
    }

    // MARK: - Notes

    @Test func eachPlainShellSaysWhy() throws {
        #expect(TmuxFallback.missing.note == "tmux isn’t installed on this server, so this tab runs a plain shell.")
        #expect(
            TmuxFallback.tooOld(try #require(TmuxVersion(name: "1.6"))).note
                == "tmux 1.6 on this server is older than 1.8, so this tab runs a plain shell.")
        #expect(
            TmuxFallback.unknown("usage: tmux").note
                == "Shello couldn’t tell which tmux this server has, so this tab runs a plain shell: usage: tmux")
        #expect(
            TmuxFallback.invalidSessionName("a b").note
                == "“a b” can’t be a tmux session name, so this tab runs a plain shell.")
    }

    /// What the server said goes into the terminal, so it loses what a terminal would read in it:
    /// escape sequences, other control characters and bidirectional overrides. It keeps one line.
    @Test(arguments: [
        ("\u{1B}[2J\u{1B}]0;title\u{7}cleared", "[2J ]0;title cleared"),
        ("\n\n  first   line \r\nsecond line\n", "first line"),
        ("tab\there", "tab here"),
        ("\u{202E}gnp.exe", "gnp.exe"),
        ("a\u{2028}b", "a"),
        (String(repeating: "x", count: 200), String(repeating: "x", count: 120)),
        ("", ""),
    ])
    func detailIsOneLineTheTerminalCanShow(_ text: String, detail: String) {
        #expect(TmuxCheck.detail(text) == detail)
    }

    // MARK: - Sessions

    @Test func sessionsAreListedInTheirFormat() async throws {
        let channels = FakeChannels(.printed("$0\t1792738688\t1\t3\tmain\n"))

        let sessions = try await Tmux.sessions(on: channels)

        #expect(
            sessions == [TmuxSession(id: "$0", name: "main", created: 1_792_738_688, attachedClients: 1, windows: 3)])
        #expect(channels.commands == ["tmux -u list-sessions -F '\(TmuxSession.listFormat)'"])
    }

    @Test(arguments: [
        "no server running on /tmp/tmux-1000/default\n", "error connecting to /tmp/tmux-1000/default (No such file)\n",
    ])
    func noTmuxServerHasNoSessions(_ message: String) async throws {
        #expect(try await Tmux.sessions(on: FakeChannels(.failed(1, message))).isEmpty)
    }

    @Test func failingListIsAnError() async {
        await #expect(throws: TmuxError.commandFailed(exitStatus: 127, "sh: tmux: not found")) {
            try await Tmux.sessions(on: FakeChannels(.failed(127, "sh: tmux: not found\n")))
        }
    }
}

/// A connection's hidden channels as a test makes them answer: every command gets the same answer,
/// and the commands are recorded.
final class FakeChannels: HiddenChannels {
    enum Answer: Sendable {
        /// The command printed this and exited with 0.
        case printed(String)
        /// The command wrote this to standard error and exited with this status.
        case failed(Int, String)
        case result(SSHCommandResult)
        case throwing(any Error)
    }

    private let answer: Answer
    private let recorded = Mutex<[String]>([])

    init(_ answer: Answer) {
        self.answer = answer
    }

    var commands: [String] { recorded.withLock { $0 } }

    func run(_ command: String) async throws -> SSHCommandResult {
        recorded.withLock { $0.append(command) }
        switch answer {
        case .printed(let output): return SSHCommandResult(output: Array(output.utf8), errorOutput: [], exitStatus: 0)
        case .failed(let status, let error):
            return SSHCommandResult(output: [], errorOutput: Array(error.utf8), exitStatus: status)
        case .result(let result): return result
        case .throwing(let error): throw error
        }
    }
}
