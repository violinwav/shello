import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import Testing

@testable import ShelloCore

/// Tabs and their lifecycle (README section 4) over a stand-in for the network and the server
/// (`FakeServer`): connecting, several tabs, the startup command, the keepalive, losing the network,
/// reconnecting with growing waits, and the background. TabIntegrationTests take the same way
/// against the test server.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalTabsTests {
    let test = TabTest()

    // MARK: - Tabs

    /// Connecting opens a tab, which connects, attaches its terminal to the login shell at the
    /// terminal's size, and becomes active; its first keepalive gives its latency.
    @Test func openedTabConnectsAndShowsItsLatency() async throws {
        let tab = test.tabs.open(TabTest.host())

        #expect(tab.state == .connecting(.connecting))
        await waitUntil { tab.state == .active && tab.latency != nil }

        #expect(tab.state == .active)
        #expect(tab.connectionCount == 1)
        #expect(tab.latency == FakeConnection.roundTrip)
        #expect(tab.terminal.attachments == 1)
        #expect(test.server.lastConnection?.shellSizes == [TerminalSize(columns: 80, rows: 24)])
        #expect(test.tabs.selectedTab === tab)
    }

    /// Several tabs at once, several for one host; each new tab comes after the selected one and is
    /// selected; next and previous go round.
    @Test func severalTabsPerHostAndSwitchingRoundThem() async throws {
        let first = try await test.openActiveTab(TabTest.host("nas"))
        let second = try await test.openActiveTab(TabTest.host("nas"))
        let third = try await test.openActiveTab(TabTest.host("web"))

        #expect(test.tabs.tabs.map(\.id) == [first.id, second.id, third.id])
        #expect(test.server.connections.count == 3)
        test.tabs.selectNext()
        #expect(test.tabs.selectedTab === first)
        test.tabs.selectPrevious()
        #expect(test.tabs.selectedTab === third)
        test.tabs.select(first)
        test.tabs.open(TabTest.host("db"))
        #expect(test.tabs.tabs.map(\.host.name) == ["nas", "db", "nas", "web"])
    }

    /// Closing a tab ends its connection; the next tab is selected at once, or the one before for
    /// the last.
    @Test func closingATabEndsItsConnectionAndSelectsANeighbour() async throws {
        let first = try await test.openActiveTab(TabTest.host("nas"))
        let second = try await test.openActiveTab(TabTest.host("web"))
        test.tabs.select(first)
        let connection = try #require(test.server.connections.first)

        let closing = test.tabs.close(first)

        #expect(test.tabs.tabs.map(\.id) == [second.id])
        #expect(test.tabs.selectedTab === second)
        await closing.value
        #expect(connection.isClosed)
        #expect(first.state == .closed)
        await test.tabs.close(second).value
        #expect(test.tabs.selectedTab == nil)
    }

    /// Closing a tab whose connection is still being made never waits for it.
    @Test func closingATabThatIsConnectingNeverWaits() async throws {
        test.server.queue(.hangs)
        let tab = test.tabs.open(TabTest.host())
        await waitUntil { test.server.tries == 1 }

        await test.tabs.close(tab).value

        #expect(tab.state == .closed)
        #expect(test.tabs.tabs.isEmpty)
    }

    // MARK: - The lifecycle

    /// Connect, verify the host key, sign in, start the session, active: a new server's host key is
    /// asked about, and a tab whose key the user does not trust closes, never having connected.
    @Test func decliningANewHostKeyClosesTheTab() async throws {
        test.server.queue(.asksToTrust(Self.hostKey))
        let tab = test.tabs.open(TabTest.host())
        await waitUntil { tab.trustQuestion != nil }

        #expect(tab.state == .connecting(.verifyingHostKey))
        #expect(tab.prompt == tab.trustQuestion.map(TerminalTab<FakeTerminal>.Prompt.trust))
        tab.answerTrust(false)
        await waitUntil { tab.state == .closed }

        #expect(test.tabs.tabs.isEmpty)
    }

    @Test func trustingANewHostKeyConnects() async throws {
        test.server.queue(.asksToTrust(Self.hostKey))
        let tab = test.tabs.open(TabTest.host())
        await waitUntil { tab.trustQuestion != nil }

        tab.answerTrust(true)
        await waitUntil { tab.state == .active }

        #expect(tab.state == .active)
        #expect(tab.prompt == nil)
    }

    /// The startup command is typed once the shell shows its prompt, its lines each with Return, so
    /// that what it sets holds in the shell (README section 3).
    @Test func startupCommandIsTypedOnceThePromptShows() async throws {
        let tab = test.tabs.open(TabTest.host(startupCommand: "cd /srv\nexport STAGE=prod\n"))
        await waitUntil { test.server.lastConnection?.shellSizes.isEmpty == false }
        let shell = try #require(test.server.lastConnection?.shell)
        try await Task.sleep(for: .milliseconds(100))

        #expect(shell.input.isEmpty)
        #expect(tab.state == .connecting(.startingSession))
        shell.print("Welcome\r\nadmin@nas:~$ ")
        await waitUntil { tab.state == .active }

        #expect(shell.input == "cd /srv\rexport STAGE=prod\r")
        #expect(tab.terminal.text.contains("admin@nas:~$ "))
    }

    /// A first connection that fails says why, and does not try again by itself.
    @Test func failedFirstConnectionSaysWhyWithoutRetrying() async throws {
        test.server.queue(.fails(.unreachable("connection refused")))
        let tab = test.tabs.open(TabTest.host())

        await waitUntil { tab.state != .connecting(.connecting) && !tab.state.isConnecting }

        #expect(tab.state == .disconnected("The server can’t be reached: connection refused."))
        #expect(test.server.tries == 1)
    }

    /// `exit` ends the shell, and the tab says so, without reconnecting; Reconnect connects again,
    /// with the terminal and its scrollback kept.
    @Test func shellThatEndsEndsTheTabUntilTheUserReconnects() async throws {
        let tab = try await test.openActiveTab()
        test.server.lastConnection?.shell.print("before exit\r\n")
        await waitUntil { tab.terminal.text.contains("before exit") }

        test.server.lastConnection?.shell.end()
        await waitUntil { tab.state == .ended }
        try await Task.sleep(for: .milliseconds(50))

        #expect(tab.state == .ended)
        #expect(test.server.tries == 1)
        #expect(test.server.connections.first?.isClosed == true)
        tab.reconnect()
        await waitUntil { tab.state == .active }
        #expect(tab.connectionCount == 2)
        #expect(tab.terminal.attachments == 2)
        #expect(tab.terminal.preparations == 1)
        #expect(tab.terminal.text.contains("before exit"))
    }

    // MARK: - Losing the connection

    /// Network loss shows "reconnecting": the tab tries at once, then waits longer after each failed
    /// try (`ReconnectPolicy`), and reconnects. The terminal keeps what the last connection showed,
    /// and is readied for the new shell.
    @Test func lostConnectionReconnectsWithGrowingWaits() async throws {
        let tab = try await test.openActiveTab()
        test.server.lastConnection?.shell.print("before the drop\r\n")
        await waitUntil { tab.terminal.text.contains("before the drop") }
        test.server.queue(
            .fails(.unreachable("no route to host")), .fails(.unreachable("no route to host")),
            .fails(.timedOut))

        test.server.connections[0].lose()
        await waitUntil {
            if case .reconnecting = tab.state { true } else { false }
        }
        #expect(tab.latency == nil)
        await waitUntil { tab.state == .active }

        #expect(tab.connectionCount == 2)
        #expect(test.server.tries == 5)
        #expect(test.sleep.durations.filter { TabTest.policy.delays.contains($0) } == TabTest.policy.delays)
        #expect(test.server.connections[0].isClosed)
        #expect(tab.terminal.preparations == 1)
        test.server.lastConnection?.shell.print("after the drop\r\n")
        await waitUntil { tab.terminal.text.contains("after the drop") }
        #expect(tab.terminal.text.contains("before the drop"))
    }

    /// After the policy's last wait, a try that fails too ends the reconnecting: the tab says why.
    @Test func reconnectingGivesUpAfterThePolicysLastWait() async throws {
        let tab = try await test.openActiveTab()
        test.server.queue(.fails(.unreachable("connection refused")), .fails(.unreachable("connection refused")))
        test.server.queue(.fails(.unreachable("connection refused")), .fails(.unreachable("connection refused")))

        test.server.connections[0].lose()
        await waitUntil { if case .disconnected = tab.state { true } else { false } }

        #expect(tab.state == .disconnected("The server can’t be reached: connection refused."))
        #expect(test.server.tries == 1 + 1 + TabTest.policy.delays.count)
    }

    /// Credentials the server no longer takes are not retried.
    @Test func refusedCredentialsAreNotRetried() async throws {
        let tab = try await test.openActiveTab()
        test.server.queue(.fails(.authenticationFailed))

        test.server.connections[0].lose()
        await waitUntil { if case .disconnected = tab.state { true } else { false } }

        #expect(tab.state == .disconnected(SSHError.authenticationFailed.description))
        #expect(test.server.tries == 2)
    }

    /// Without a network, the tab waits for one, trying nothing; once it is back, the tab reconnects
    /// at once (NWPathMonitor, STACK section 7.1).
    @Test func withoutANetworkTheTabWaitsThenReconnectsAtOnce() async throws {
        let tab = try await test.openActiveTab()
        test.network.set(available: false)
        await waitUntil { !test.tabs.isNetworkAvailable }

        test.server.connections[0].lose()
        await waitUntil {
            if case .reconnecting(let reconnecting) = tab.state {
                reconnecting.phase == .waitingForNetwork
            } else {
                false
            }
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(test.server.tries == 1)
        test.network.set(available: true)
        await waitUntil { tab.state == .active }
        #expect(test.server.tries == 2)
        #expect(tab.connectionCount == 2)
    }

    /// A keepalive that the server leaves unanswered for three intervals means the connection is
    /// gone: the tab reconnects.
    @Test func unansweredKeepaliveReconnects() async throws {
        test.server.setKeepaliveAnswers(false)
        let tab = try await test.openActiveTab(TabTest.host(keepalive: .milliseconds(20)))
        test.server.setKeepaliveAnswers(true)

        await waitUntil { tab.connectionCount == 2 && tab.state == .active }

        #expect(tab.connectionCount == 2)
        #expect(test.server.connections[0].isClosed)
        #expect(test.sleep.durations.contains(.milliseconds(60)))
    }

    /// The keepalive goes every keepalive interval.
    @Test func keepaliveGoesEveryInterval() async throws {
        _ = try await test.openActiveTab(TabTest.host(keepalive: .milliseconds(20)))
        let connection = try #require(test.server.lastConnection)

        await waitUntil { connection.keepalives >= 3 }

        #expect(connection.keepalives >= 3)
    }

    /// A network that goes from under the connection and comes back within the grace changes
    /// nothing.
    @Test func networkThatComesBackKeepsTheConnection() async throws {
        let tab = try await test.openActiveTab()
        let connection = try #require(test.server.lastConnection)

        connection.path(.viable(false))
        try await Task.sleep(for: .milliseconds(50))
        connection.path(.viable(true))
        try await Task.sleep(for: .milliseconds(300))

        #expect(tab.state == .active)
        #expect(tab.connectionCount == 1)
        #expect(!connection.isClosed)
    }

    /// A network that stays away past the grace: the tab reconnects.
    @Test func networkThatStaysAwayReconnects() async throws {
        let tab = try await test.openActiveTab()
        let connection = try #require(test.server.lastConnection)

        connection.path(.viable(false))
        await waitUntil { tab.connectionCount == 2 && tab.state == .active }

        #expect(tab.connectionCount == 2)
        #expect(connection.isClosed)
    }

    /// A better path while the connection's has gone, such as cellular once the Wi-Fi went:
    /// the tab reconnects over it at once, without waiting for the grace.
    @Test func betterPathAfterTheNetworkWentReconnectsAtOnce() async throws {
        let test = TabTest(viabilityGrace: .seconds(30))
        let tab = try await test.openActiveTab()
        let connection = try #require(test.server.lastConnection)

        connection.path(.viable(false))
        connection.path(.betterPathAvailable(true))
        await waitUntil { tab.connectionCount == 2 && tab.state == .active }

        #expect(tab.connectionCount == 2)
    }

    /// A better path for a connection that works changes nothing: moving would end the shell.
    @Test func betterPathForAWorkingConnectionChangesNothing() async throws {
        let tab = try await test.openActiveTab()
        let connection = try #require(test.server.lastConnection)

        connection.path(.betterPathAvailable(true))
        try await Task.sleep(for: .milliseconds(100))

        #expect(tab.state == .active)
        #expect(tab.connectionCount == 1)
    }

    // MARK: - The background

    /// In the background the connections stay for the time iOS grants, then close; back in the
    /// foreground, the tab on screen reconnects at once and the others once selected (README
    /// section 4).
    @Test func backgroundClosesTheConnectionsAndTheTabOnScreenReconnects() async throws {
        let first = try await test.openActiveTab(TabTest.host("nas"))
        let second = try await test.openActiveTab(TabTest.host("web"))
        test.tabs.isOnScreen = true

        await test.tabs.enterBackground(closingConnectionsAfter: .milliseconds(20))

        #expect(first.state == .suspended)
        #expect(second.state == .suspended)
        #expect(test.server.connections.allSatisfy { $0.isClosed })
        test.tabs.canConnect = false
        test.tabs.enterForeground()
        try await Task.sleep(for: .milliseconds(50))
        #expect(test.server.tries == 2)
        test.tabs.canConnect = true
        await waitUntil { second.state == .active }
        #expect(second.connectionCount == 2)
        #expect(first.state == .suspended)
        test.tabs.select(first)
        await waitUntil { first.state == .active }
        #expect(first.connectionCount == 2)
        #expect(test.server.tries == 4)
    }

    /// Back before the background time ran out, the connections are still there.
    @Test func returningInTimeKeepsTheConnections() async throws {
        let tab = try await test.openActiveTab()
        test.tabs.isOnScreen = true

        async let closed: Void = test.tabs.enterBackground(closingConnectionsAfter: .seconds(30))
        try await Task.sleep(for: .milliseconds(20))
        test.tabs.enterForeground()
        await closed

        #expect(tab.state == .active)
        #expect(test.server.lastConnection?.isClosed == false)
    }

    /// A suspended tab that is not on screen waits until it is.
    @Test func suspendedTabWaitsUntilItIsOnScreen() async throws {
        let tab = try await test.openActiveTab()

        await test.tabs.closeConnections()
        try await Task.sleep(for: .milliseconds(50))

        #expect(tab.state == .suspended)
        #expect(test.server.tries == 1)
        test.tabs.isOnScreen = true
        await waitUntil { tab.state == .active }
        #expect(tab.connectionCount == 2)
    }

    /// Going to the background while a connection is being made stops it; it is made again once
    /// the tab is back on screen.
    @Test func backgroundStopsAConnectionBeingMade() async throws {
        test.server.queue(.hangs)
        let tab = test.tabs.open(TabTest.host())
        await waitUntil { test.server.tries == 1 }

        await test.tabs.closeConnections()

        #expect(tab.state == .suspended)
        test.tabs.isOnScreen = true
        await waitUntil { tab.state == .active }
        #expect(test.server.tries == 2)
    }

    static let hostKey = HostKey(
        algorithm: "ssh-ed25519", wireRepresentation: Data([1, 2, 3]), fingerprint: "SHA256:fixture")
}

/// A host's startup command, typed as the user would: each line with Return.
struct StartupCommandTests {
    @Test(arguments: [
        ("tmux new -A -s main", "tmux new -A -s main\r"),
        ("cd /srv\nexport STAGE=prod", "cd /srv\rexport STAGE=prod\r"),
        ("cd /srv\r\nls\n\n  \n", "cd /srv\rls\r"),
        (" history-free", " history-free\r"),
    ])
    func linesAreTypedWithReturn(_ command: String, typed: String) throws {
        #expect(try #require(StartupCommand(command)).bytes == Array(typed.utf8))
    }

    @Test(arguments: ["", "  ", "\n\n"])
    func emptyCommandTypesNothing(_ command: String) {
        #expect(StartupCommand(command) == nil)
    }
}

/// The waits between tries to reconnect.
struct ReconnectPolicyTests {
    @Test func standardWaitsDoubleUpToHalfAMinuteThenGiveUp() {
        let policy = ReconnectPolicy.standard

        let waits = (1...7).map { policy.delay(afterFailedAttempts: $0) }

        #expect(waits == [1, 2, 4, 8, 16, 30].map { Duration.seconds($0) } + [nil])
        #expect(policy.delay(afterFailedAttempts: 0) == nil)
    }
}
