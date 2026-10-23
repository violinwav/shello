import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloStorage
import Testing

@testable import ShelloCore

/// Tabs against the test server (TestServers/README.md), signing in with the client key through
/// Shello's SSH agent, as CI's sshd allows: from Connect to the prompt and the startup command, the
/// keepalive, the terminal's size, and reconnecting after the network broke, through a proxy that
/// breaks it (`FaultyProxy`). Skipped when the server is not running.
@MainActor
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(2)))
struct TabIntegrationTests {
    let test: TestConnector

    init() throws {
        test = try TestConnector()
    }

    /// The tab reaches the server's prompt within README section 16's two seconds, then runs the
    /// startup command in the shell, shows the keepalive's round trip as its latency, and records the
    /// connection for Recents.
    @Test func tabReachesThePromptThenRunsTheStartupCommand() async throws {
        var host = try test.keyHost()
        host.startupCommand = "echo started-$((6 * 7))"
        try await test.hosts.create(host)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let tabs = tabs()

        let tab = tabs.open(host)

        await waitUntil(timeout: .seconds(30)) { tab.terminal.text.contains("started-42") }
        #expect(tab.terminal.text.contains("started-42"))
        #expect(tab.state == .active)
        #expect(try #require(tab.timeToPrompt) < .seconds(2))
        await waitUntil { tab.latency != nil }
        #expect(try #require(tab.latency) < .seconds(1))
        try await waitUntilConnectionIsRecorded(host)
        await tabs.close(tab).value
    }

    /// A network that drops shows "reconnecting"; the tries fail while it is down, each waiting
    /// longer, and once it is back the tab reconnects, with what the terminal showed kept.
    @Test func droppedNetworkShowsReconnectingThenReconnects() async throws {
        let proxy = try await FaultyProxy(to: TestServer.port)
        let host = try await proxyHost(proxy)
        let tabs = tabs(policy: ReconnectPolicy(delays: Array(repeating: .milliseconds(200), count: 20)))
        let tab = tabs.open(host)
        await waitUntil(timeout: .seconds(30)) { tab.state == .active }
        try #require(tab.state == .active)
        tab.terminal.type("echo before-$((1 + 1))\r")
        await waitUntil { tab.terminal.text.contains("before-2") }

        proxy.cut()
        // Up to 30 seconds, as for connecting (`TestConnector.host(password:)`): a try that the proxy
        // refuses fails at once here, but on CI's runner one was held up for 12 seconds, and went
        // through once the proxy was restored.
        await waitUntil(timeout: .seconds(30)) { tab.reconnecting?.failedAttempts ?? 0 >= 2 }

        #expect(tab.reconnecting?.failedAttempts ?? 0 >= 2)
        #expect(tab.latency == nil)
        proxy.restore()
        await waitUntil(timeout: .seconds(30)) { tab.state == .active }
        #expect(tab.connectionCount == 2)
        tab.terminal.type("echo after-$((2 + 2))\r")
        await waitUntil { tab.terminal.text.contains("after-4") }
        #expect(tab.terminal.text.contains("before-2"))
        await tabs.close(tab).value
    }

    /// A network that goes silent closes nothing: the keepalive finds it, unanswered for three
    /// intervals, and the tab reconnects once the network is back.
    @Test func silentNetworkIsFoundByTheKeepalive() async throws {
        let proxy = try await FaultyProxy(to: TestServer.port)
        var host = try await proxyHost(proxy)
        host.keepaliveInterval = .milliseconds(300)
        host.connectTimeout = .seconds(2)
        let tabs = tabs(policy: ReconnectPolicy(delays: Array(repeating: .milliseconds(200), count: 20)))
        let tab = tabs.open(host)
        await waitUntil(timeout: .seconds(30)) { tab.state == .active && tab.latency != nil }
        try #require(tab.state == .active)

        proxy.stall()
        await waitUntil { tab.reconnecting != nil }

        #expect(tab.reconnecting != nil)
        proxy.restore()
        await waitUntil(timeout: .seconds(30)) { tab.state == .active }
        #expect(tab.connectionCount == 2)
        await tabs.close(tab).value
    }

    /// The terminal's new size reaches the server, and a new connection's shell starts at it.
    @Test func terminalSizeReachesTheServer() async throws {
        let host = try test.keyHost()
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let tabs = tabs()
        let tab = tabs.open(host)
        await waitUntil(timeout: .seconds(30)) { tab.state == .active }

        tab.terminal.resize(to: TerminalSize(columns: 100, rows: 30))
        tab.terminal.type("stty size\r")
        await waitUntil { tab.terminal.text.contains("30 100") }
        #expect(tab.terminal.text.contains("30 100"))

        tab.terminal.type("exit\r")
        await waitUntil { tab.state == .ended }
        tab.reconnect()
        await waitUntil(timeout: .seconds(30)) { tab.state == .active }
        tab.terminal.type("echo size; stty size\r")
        await waitUntil { tab.terminal.text.components(separatedBy: "30 100").count == 3 }
        #expect(tab.terminal.text.components(separatedBy: "30 100").count == 3)
        await tabs.close(tab).value
    }

    /// Closing a tab, or Shello leaving the background time, while Face ID waits for an SSH key that
    /// signs on every use: neither waits for the user, and the prompt goes.
    @Test(arguments: [true, false])
    func closingWhileFaceIDWaitsNeverWaits(closesTheTab: Bool) async throws {
        let faceID = PendingAuthentication()
        let test = try TestConnector(clientKeyPolicy: .everyUse, faceID: faceID)
        let host = try test.keyHost()
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let tabs = TerminalTabs(
            services: TabServices(connector: test.connector, network: FakeNetworkMonitor()),
            makeTerminal: { _ in FakeTerminal() })
        let tab = tabs.open(host)
        await waitUntil(timeout: .seconds(30)) { faceID.openPromptCount == 1 }
        try #require(faceID.openPromptCount == 1)
        #expect(tab.state == .connecting(.signingIn))

        let clock = ContinuousClock()
        let start = clock.now
        if closesTheTab {
            await tabs.close(tab).value
        } else {
            await tabs.closeConnections()
        }

        #expect(clock.now - start < .seconds(2))
        #expect(faceID.openPromptCount == 0)
        #expect(tab.state == (closesTheTab ? .closed : .suspended))
    }

    /// Tap to prompt (README section 16: under two seconds to a usable prompt on a known host), over
    /// ten connections to the test server on this device: the signpost interval "Prompt", measured
    /// by the tab. Printed for the report, and held to the goal at the median.
    @Test func tapToPromptMeetsTheTwoSecondGoal() async throws {
        let host = try test.keyHost()
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let tabs = tabs()
        var times: [Duration] = []
        for _ in 0..<10 {
            let tab = tabs.open(host)
            await waitUntil(timeout: .seconds(30)) { tab.timeToPrompt != nil }
            times.append(try #require(tab.timeToPrompt))
            await tabs.close(tab).value
        }

        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        print(
            "Tap to prompt over \(times.count) connections to \(TestServer.server): median "
                + "\(median.wholeMilliseconds) ms, fastest \(sorted[0].wholeMilliseconds) ms, slowest "
                + "\(sorted[sorted.count - 1].wholeMilliseconds) ms")
        #expect(median < .seconds(2))
    }

    // MARK: - Helpers

    private func tabs(policy: ReconnectPolicy = .standard) -> TerminalTabs<FakeTerminal> {
        TerminalTabs(
            services: TabServices(
                connector: test.connector, hosts: test.hosts, network: FakeNetworkMonitor(), reconnectPolicy: policy),
            makeTerminal: { _ in FakeTerminal() })
    }

    /// The client key's host for the test server, through `proxy`, whose host key is trusted.
    private func proxyHost(_ proxy: FaultyProxy) async throws -> Host {
        var host = try test.keyHost(port: proxy.port)
        host.address = "127.0.0.1"
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        return host
    }

    private func waitUntilConnectionIsRecorded(_ host: Host) async throws {
        var recorded: Date?
        let deadline = ContinuousClock.now + .seconds(5)
        while recorded == nil, ContinuousClock.now < deadline {
            recorded = try await test.hosts.host(id: host.id)?.lastConnectedAt
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(recorded != nil)
    }
}

extension TerminalTab {
    /// What the tab's reconnecting is at, while it reconnects.
    var reconnecting: Reconnecting? {
        if case .reconnecting(let reconnecting) = state { reconnecting } else { nil }
    }
}

extension Duration {
    /// Whole milliseconds, for the printed timings.
    var wholeMilliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
