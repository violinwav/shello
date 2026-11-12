import Foundation
import ShelloModel
import ShelloSSH
import ShelloTmux
import Testing

@testable import ShelloCore

/// tmux auto-attach (README section 8) against the test servers (TestServers/README.md): a tab
/// attaches its host's tmux session, the network drops under it, through a proxy that breaks it
/// (`FaultyProxy`), and the tab reconnects into the same tmux session, with what ran in it; a server
/// without tmux gets a plain shell. Each test skips, saying why, when its server, or its server's
/// tmux, is not there.
@MainActor
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(2)))
struct TmuxIntegrationTests {
    let test: TestConnector

    init() throws {
        test = try TestConnector()
    }

    /// Connect with auto-attach on, set something in the tmux session's shell, drop the connection,
    /// reconnect: the tab is in the same tmux session, the same tmux identifier and start, and its
    /// shell still has what was set. The old client is gone before the reconnect, so the attached
    /// client found afterwards is the tab's new one.
    @Test(.enabled(TmuxTestServer.noTmux) { await TmuxTestServer.hasTmux })
    func reconnectReattachesTheSameTmuxSessionWithItsState() async throws {
        let session = TmuxTestServer.uniqueSessionName()
        let queries = try await TmuxTestServer.signedInConnection(port: TestServer.port, test: test)
        do {
            let proxy = try await FaultyProxy(to: TestServer.port)
            var host = try test.keyHost(port: proxy.port)
            host.address = "127.0.0.1"
            host.tmuxAutoAttach = true
            host.tmuxSessionName = session
            try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
            let tabs = tabs(policy: ReconnectPolicy(delays: Array(repeating: .milliseconds(200), count: 50)))
            let tab = tabs.open(host)
            await waitUntil(timeout: .seconds(30)) { tab.state == .active }
            try #require(tab.state == .active)
            guard case .attaching(let name, _)? = tab.tmux else {
                Issue.record("The tab does not attach the tmux session: \(String(describing: tab.tmux))")
                await tabs.close(tab).value
                return
            }
            #expect(name.rawValue == session)
            let before = try await TmuxTestServer.waitForSession(session, attachedClients: 1, on: queries)
            // In the tmux session's shell. The marks have no letter twice in a row, which tmux may draw
            // as one letter repeated.
            tab.terminal.type("SHELLO_STATE=held-$((40 + 2)); echo set-$((40 + 2))\r")
            await waitUntil { tab.terminal.text.contains("set-42") }
            try #require(tab.terminal.text.contains("set-42"))

            proxy.cut()
            await waitUntil { tab.reconnecting != nil }
            _ = try await TmuxTestServer.waitForSession(session, attachedClients: 0, on: queries)
            proxy.restore()
            await waitUntil(timeout: .seconds(30)) { tab.state == .active && tab.connectionCount == 2 }
            try #require(tab.connectionCount == 2)
            let after = try await TmuxTestServer.waitForSession(session, attachedClients: 1, on: queries)

            #expect(after.id == before.id)
            #expect(after.created == before.created)
            tab.terminal.type("echo \"state-$SHELLO_STATE\"\r")
            await waitUntil { tab.terminal.text.contains("state-held-42") }
            #expect(tab.terminal.text.contains("state-held-42"))
            await tabs.close(tab).value
        } catch {
            await TmuxTestServer.kill(session, on: queries)
            await queries.close()
            throw error
        }
        await TmuxTestServer.kill(session, on: queries)
        await queries.close()
    }

    /// A server without tmux: the tab runs a plain shell, which works, after the startup command, and
    /// its terminal says why. Nothing is typed for tmux.
    @Test(.enabled(TmuxTestServer.noServerWithoutTmux) { await TmuxTestServer.portWithoutTmux != nil })
    func serverWithoutTmuxGetsAPlainShellThatSaysWhy() async throws {
        let port = try #require(await TmuxTestServer.portWithoutTmux)
        var host = try test.keyHost(port: port)
        host.tmuxAutoAttach = true
        host.startupCommand = "echo started-$((6 * 7))"
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let tabs = tabs()

        let tab = tabs.open(host)

        await waitUntil(timeout: .seconds(30)) { tab.terminal.text.contains("started-42") }
        #expect(tab.state == .active)
        #expect(tab.tmux == .plainShell(.missing))
        #expect(tab.terminal.notes == [TmuxFallback.missing.note])
        tab.terminal.type("echo plain-$((1 + 2))\r")
        await waitUntil { tab.terminal.text.contains("plain-3") }
        #expect(tab.terminal.text.contains("plain-3"))
        #expect(!tab.terminal.text.contains("new-session"))
        await tabs.close(tab).value
    }

    /// The parsers read what each test server's tmux prints: its version, and its sessions in
    /// Shello's format, a new one among them.
    @Test(.enabled(TmuxTestServer.noTmux) { await TmuxTestServer.hasTmux })
    func parsersReadWhatEachServersTmuxPrints() async throws {
        var checked: [String] = []
        for port in TmuxTestServer.portsWithTmux {
            guard let queries = try? await TmuxTestServer.signedInConnection(port: port, test: test) else { continue }
            guard case .available(let version) = try await Tmux.check(on: queries) else {
                await queries.close()
                continue
            }
            let session = TmuxTestServer.uniqueSessionName()
            let started = try await queries.run("tmux new-session -d -s \(session)")
            #expect(started.exitStatus == 0, "\(String(decoding: started.errorOutput, as: UTF8.self))")
            let listed = try await Tmux.sessions(on: queries).first { $0.name == session }
            #expect(listed?.id.hasPrefix("$") == true)
            #expect(listed?.windows == 1)
            #expect(listed?.attachedClients == 0)
            await TmuxTestServer.kill(session, on: queries)
            await queries.close()
            checked.append("tmux \(version) on port \(port)")
        }
        print("Read the version and the sessions of \(checked.joined(separator: ", "))")
        #expect(!checked.isEmpty)
    }

    // MARK: - Helpers

    private func tabs(policy: ReconnectPolicy = .standard) -> TerminalTabs<FakeTerminal> {
        TerminalTabs(
            services: TabServices(
                connector: test.connector, hosts: test.hosts, network: FakeNetworkMonitor(), reconnectPolicy: policy),
            makeTerminal: { _ in FakeTerminal() })
    }
}

/// tmux on the test servers (TestServers/README.md). In Docker, the OpenSSH 10 and 9 servers have
/// tmux, 3.7c on ports 2222, 2224 and 2226 and 3.4 on port 2223, and the OpenSSH 8.8 server on port
/// 2225 has none. This Mac's own sshd (`local-sshd.sh`) has the Mac's tmux, if it has one, on port
/// 2222, and none on port 2224.
enum TmuxTestServer {
    static let noTmux: Comment =
        "tmux is not installed on the test server on localhost:2222. TestServers/README.md says how to get it."
    static let noServerWithoutTmux: Comment =
        "No test server without tmux is running: the Docker server on localhost:2225, or this Mac's own sshd on localhost:2224 (TestServers/README.md)."

    /// The ports where a test server may have tmux.
    static let portsWithTmux: [UInt16] = [2222, 2223]

    /// Whether the test server on port 2222 has a tmux that Shello attaches with.
    static var hasTmux: Bool {
        get async {
            if case .available = await tmuxOnPort2222.value { true } else { false }
        }
    }

    private static let tmuxOnPort2222 = Task { await check(port: TestServer.port) }

    /// The port of a test server that runs, and has no tmux: 2225 in Docker, or 2224 with this Mac's
    /// own sshd.
    static var portWithoutTmux: UInt16? {
        get async { await withoutTmux.value }
    }

    private static let withoutTmux = Task { () -> UInt16? in
        for port: UInt16 in [2225, 2224] {
            if await check(port: port) == .missing {
                return port
            }
        }
        return nil
    }

    /// What `Tmux.check(on:)` finds on the test server on `port`, or nil if Shello cannot sign in to
    /// one there.
    static func check(port: UInt16) async -> TmuxCheck? {
        guard await TestServer.hasSSHBanner(port: port), let test = try? TestConnector(),
            let connection = try? await signedInConnection(port: port, test: test)
        else { return nil }
        let check = try? await Tmux.check(on: connection)
        await connection.close()
        return check
    }

    /// A connection to the test server on `port` for hidden channels of the test's own, signed in with
    /// the client key, as the test user.
    static func signedInConnection(port: UInt16, test: TestConnector) async throws -> SSHConnection {
        let host = try test.keyHost(port: port)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        return try await test.connector.connect(to: host, askToTrust: { _, _ in false })
    }

    /// A name no other test run uses.
    static func uniqueSessionName() -> String {
        "shello-test-\(UUID().uuidString.prefix(8))"
    }

    /// Waits until the tmux session `name` runs with `attachedClients` clients, and returns it.
    static func waitForSession(
        _ name: String, attachedClients: Int, on connection: SSHConnection, timeout: Duration = .seconds(20)
    ) async throws -> TmuxSession {
        let deadline = ContinuousClock.now + timeout
        while true {
            let session = try await Tmux.sessions(on: connection).first { $0.name == name }
            if let session, session.attachedClients == attachedClients {
                return session
            }
            guard ContinuousClock.now < deadline else {
                throw SessionNotReached(name: name, attachedClients: attachedClients, found: session)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The tmux session did not get to the clients the test waited for.
    struct SessionNotReached: Error, CustomStringConvertible {
        let name: String
        let attachedClients: Int
        let found: TmuxSession?

        var description: String {
            "The tmux session \(name) does not have \(attachedClients) clients attached: \(String(describing: found))"
        }
    }

    /// Ends the tmux session `name`, if it runs.
    static func kill(_ name: String, on connection: SSHConnection) async {
        _ = try? await connection.run("tmux kill-session -t '=\(name)'")
    }
}
