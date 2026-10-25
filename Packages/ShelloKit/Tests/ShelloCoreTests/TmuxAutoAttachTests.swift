import Foundation
import ShelloModel
import ShelloSSH
import ShelloTmux
import Testing

@testable import ShelloCore

/// tmux auto-attach (README section 8) over a stand-in for the network and the server
/// (`FakeServer`): each connection checks the server's tmux on a hidden channel, then types the
/// startup command and the command that attaches the host's tmux session, on the first connection
/// and again on each reconnect; without a tmux it can use, the tab runs a plain shell, and its
/// terminal says why. TmuxIntegrationTests take the same way against the test servers.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TmuxAutoAttachTests {
    let test = TabTest()

    /// The startup command runs first, in the login shell, then the tmux session is attached, so
    /// that what the command sets reaches a tmux session that starts now.
    @Test func attachesTheSessionAfterTheStartupCommandOnceThePromptShows() async throws {
        let tab = test.tabs.open(Self.host(startupCommand: "cd /srv", session: "work"))
        await waitUntil { test.server.lastConnection?.shellSizes.isEmpty == false }
        let connection = try #require(test.server.lastConnection)
        try await Task.sleep(for: .milliseconds(100))

        #expect(connection.shell.input.isEmpty)
        connection.shell.print("Welcome\r\nadmin@nas:~$ ")
        await waitUntil { tab.state == .active }

        #expect(connection.shell.input == "cd /srv\r tmux -u new-session -A -s 'work'\r")
        #expect(connection.commands == ["tmux -V"])
        #expect(!connection.shellOpenedWhileACommandRan)
        #expect(tab.tmux == .attaching(try #require(TmuxSessionName("work")), try #require(TmuxVersion(name: "3.4"))))
        #expect(tab.terminal.notes.isEmpty)
        #expect(tab.plainShellNote == nil)
    }

    @Test func attachesWithoutAStartupCommandToo() async throws {
        let tab = test.tabs.open(Self.host(session: "main"))
        await waitUntil { test.server.lastConnection?.shellSizes.isEmpty == false }
        let connection = try #require(test.server.lastConnection)

        connection.shell.print("admin@nas:~$ ")
        await waitUntil { tab.state == .active }

        #expect(connection.shell.input == " tmux -u new-session -A -s 'main'\r")
    }

    /// A reconnect checks tmux again, on the new connection, and reattaches the same tmux session.
    @Test func reconnectReattachesTheSameSession() async throws {
        let tab = try await activeTab(Self.host(session: "work"))
        let first = try #require(test.server.lastConnection)

        first.lose()
        await waitUntil { tab.connectionCount == 2 || test.server.connections.count == 2 }
        let second = try #require(test.server.connections.last)
        await waitUntil { second.shellSizes.isEmpty == false }
        second.shell.print("admin@nas:~$ ")
        await waitUntil { tab.state == .active && tab.connectionCount == 2 }

        #expect(second.commands == ["tmux -V"])
        #expect(second.shell.input == first.shell.input)
        #expect(second.shell.input == " tmux -u new-session -A -s 'work'\r")
    }

    /// Without a tmux to attach with, the tab runs a plain shell: the startup command still runs, no
    /// tmux command is typed, and the terminal says why, before the shell's first output. The tab
    /// has the note for VoiceOver by the time it is active.
    @Test(arguments: [
        (FakeTmux.missing, TmuxFallback.missing),
        (.installed("tmux 1.6\n"), .tooOld(TmuxVersion(name: "1.6")!)),
        (.installed("usage: tmux [-28lquv]\n"), .unknown("usage: tmux [-28lquv]")),
        (.fails(.channelRefused("prohibited")), .unknown("The server refused the request: prohibited.")),
    ])
    func withoutAUsableTmuxTheTabRunsAPlainShellAndSaysWhy(_ tmux: FakeTmux, fallback: TmuxFallback) async throws {
        test.server.setTmux(tmux)
        let tab = test.tabs.open(Self.host(startupCommand: "cd /srv", session: "work"))
        await waitUntil { test.server.lastConnection?.shellSizes.isEmpty == false }
        let connection = try #require(test.server.lastConnection)

        connection.shell.print("Welcome\r\nadmin@nas:~$ ")
        await waitUntil { tab.state == .active }

        #expect(connection.shell.input == "cd /srv\r")
        #expect(tab.tmux == .plainShell(fallback))
        #expect(tab.plainShellNote == fallback.note)
        #expect(tab.terminal.notes == [fallback.note])
        #expect(tab.terminal.text.hasPrefix("Shello: \(fallback.note)\r\nWelcome"))
    }

    /// Each connection checks tmux again: one after tmux was installed attaches the session.
    @Test func eachConnectionChecksTmuxAgain() async throws {
        test.server.setTmux(.missing)
        let tab = try await activeTab(Self.host(session: "work"))

        test.server.setTmux(.installed("tmux 3.4\n"))
        test.server.lastConnection?.lose()
        await waitUntil { test.server.connections.count == 2 }
        let second = try #require(test.server.connections.last)
        await waitUntil { second.shellSizes.isEmpty == false }
        second.shell.print("$ ")
        await waitUntil { tab.state == .active && tab.connectionCount == 2 }

        #expect(tab.terminal.notes == [TmuxFallback.missing.note])
        #expect(second.shell.input == " tmux -u new-session -A -s 'work'\r")
        #expect(tab.plainShellNote == nil)
    }

    /// A tmux that does not answer holds the connection up for its connect timeout at most.
    @Test func checkThatNeverEndsGivesUpAfterTheConnectTimeout() async throws {
        test.server.setTmux(.hangs)
        var host = Self.host(session: "work")
        host.connectTimeout = .milliseconds(200)
        let tab = test.tabs.open(host)
        await waitUntil { test.server.lastConnection?.shellSizes.isEmpty == false }
        let connection = try #require(test.server.lastConnection)

        connection.shell.print("$ ")
        await waitUntil { tab.state == .active }

        #expect(tab.tmux == .plainShell(.unknown("tmux didn’t answer in time")))
        #expect(connection.shell.input.isEmpty)
        #expect(test.sleep.durations.contains(.milliseconds(200)))
    }

    /// A connection lost under the check ends the try, as any connection lost while it starts: the
    /// first connection says why.
    @Test func connectionLostUnderTheCheckEndsTheTry() async throws {
        test.server.setTmux(.fails(.connectionLost("the network dropped the connection")))
        let tab = test.tabs.open(Self.host(session: "work"))

        await waitUntil { !tab.state.isConnecting }

        #expect(tab.state == .disconnected("The connection ended: the network dropped the connection."))
        #expect(test.server.lastConnection?.shellSizes.isEmpty == true)
        #expect(tab.terminal.notes.isEmpty)
    }

    /// With auto-attach off, nothing is asked of tmux and nothing typed but the startup command.
    @Test func withAutoAttachOffTmuxIsNotAsked() async throws {
        var host = Self.host(startupCommand: "cd /srv", session: "work")
        host.tmuxAutoAttach = false
        let tab = test.tabs.open(host)
        await waitUntil { test.server.lastConnection?.shellSizes.isEmpty == false }
        let connection = try #require(test.server.lastConnection)

        connection.shell.print("$ ")
        await waitUntil { tab.state == .active }

        #expect(connection.commands.isEmpty)
        #expect(connection.shell.input == "cd /srv\r")
        #expect(tab.tmux == nil)
    }

    /// A name the host editor would refuse, as only a damaged database could hold, is never typed.
    @Test func invalidSessionNameIsNeverTyped() async throws {
        let tab = test.tabs.open(Self.host(session: "x'; reboot; '"))
        await waitUntil { test.server.lastConnection?.shellSizes.isEmpty == false }
        let connection = try #require(test.server.lastConnection)

        connection.shell.print("$ ")
        await waitUntil { tab.state == .active }

        #expect(connection.commands.isEmpty)
        #expect(connection.shell.input.isEmpty)
        #expect(tab.tmux == .plainShell(.invalidSessionName("x'; reboot; '")))
    }

    // MARK: - Helpers

    private static func host(startupCommand: String = "", session: String) -> Host {
        var host = TabTest.host(startupCommand: startupCommand)
        host.tmuxAutoAttach = true
        host.tmuxSessionName = session
        return host
    }

    /// Opens a tab for `host`, has its shell show a prompt, and waits until it is active.
    private func activeTab(_ host: Host) async throws -> TerminalTab<FakeTerminal> {
        let tab = test.tabs.open(host)
        await waitUntil { test.server.lastConnection?.shellSizes.isEmpty == false }
        test.server.lastConnection?.shell.print("admin@nas:~$ ")
        await waitUntil { tab.state == .active }
        try #require(tab.state == .active)
        return tab
    }
}
