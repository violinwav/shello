import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloStorage
import ShelloTmux
import Synchronization
import Testing

@testable import ShelloCore

/// Hosts behind jump hosts (README section 3) against the test servers (TestServers/README.md): in
/// Docker, the server on port 2222 reaches the others by name on the servers' network; this Mac's own
/// sshd, as in CI, reaches itself on its other ports. A tab reaches a working shell through one jump
/// host and through two, trusting each hop's host key on first use; a changed host key on a jump host
/// stops the route there; each hop signs in its own way; and a first hop that drops reconnects the
/// whole route, reattaching the tmux session. Skipped when the servers are not running.
@MainActor
@Suite(
    .serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning },
    .enabled(TestServer.jumpServersNotRunning) { await TestServer.areJumpServersRunning },
    .timeLimit(.minutes(2)))
struct JumpHostIntegrationTests {
    let test: TestConnector

    init() throws {
        test = try TestConnector()
    }

    /// Connect asks to trust each hop's host key, the jump host's first, each under its own server,
    /// and the tab reaches a working shell on its host, two connections deep. The tab's latency is
    /// the keepalive's round trip through the jump host.
    @Test func hostBehindAJumpHostTrustsEachHostKeyOnFirstUseAndReachesAShell() async throws {
        let bastion = try jumpHost()
        let web = try keyHost("web-01", at: TestServer.reachedFromAnother(port: 2224), through: [bastion])
        try await save(bastion, web)
        let tabs = tabs()

        let tab = tabs.open(web)
        let asked = await trustEveryHostKey(of: tab)

        #expect(tab.state == .active)
        #expect(
            asked == [
                RouteHop(name: "bastion", place: .jumpHost(destination: "web-01")),
                RouteHop(name: "web-01", place: .behindJumpHost("bastion")),
            ])
        #expect(try await test.hostKeys.trustedKey(of: bastion.server)?.key == TestServer.hostKeyA)
        #expect(try await test.hostKeys.trustedKey(of: web.server)?.key == TestServer.hostKeyA)
        tab.terminal.type("echo through-$((6 * 7))\r")
        await waitUntil { tab.terminal.text.contains("through-42") }
        #expect(tab.terminal.text.contains("through-42"))
        // OpenSSH 10 with post-quantum key exchange, then without it.
        #expect(tab.keyExchanges.map(\.hostName) == ["bastion", "web-01"])
        #expect(tab.keyExchanges.map { $0.keyExchange?.isPostQuantum } == [true, false])
        await waitUntil { tab.latency != nil }
        #expect(tab.latency != nil)
        print("Tap to prompt through a jump host, trust questions included: \(tab.timeToPrompt.map { "\($0)" } ?? "?")")
        await tabs.close(tab).value
    }

    @Test func hostBehindTwoJumpHostsReachesAShell() async throws {
        let bastion = try jumpHost()
        let inner = try keyHost("inner", at: TestServer.reachedFromAnother(port: 2224))
        let web = try keyHost("web-01", at: TestServer.reachedFromAnother(port: 2226), through: [bastion, inner])
        try await save(bastion, inner, web)
        let tabs = tabs()

        let tab = tabs.open(web)
        let asked = await trustEveryHostKey(of: tab)

        #expect(tab.state == .active)
        #expect(asked.map(\.name) == ["bastion", "inner", "web-01"])
        #expect(asked.last?.place == .behindJumpHost("inner"))
        tab.terminal.type("echo two-hops-$((40 + 2))\r")
        await waitUntil { tab.terminal.text.contains("two-hops-42") }
        #expect(tab.terminal.text.contains("two-hops-42"))
        #expect(tab.keyExchanges.last?.keyExchange?.name == "ecdh-sha2-nistp256")
        await tabs.close(tab).value
    }

    /// The jump host presents key a while key b is trusted for its server: the route stops there and
    /// says so. Nobody is asked anything, the host behind it is never reached, so its host key is not
    /// trusted, and its password is never read.
    @Test func changedHostKeyOnAJumpHostBlocksTheRouteThereAndSendsNothingPastIt() async throws {
        let bastion = try jumpHost()
        try await test.hostKeys.trust(TestServer.hostKeyB, of: bastion.server)
        let trusted = try #require(try await test.hostKeys.trustedKey(of: bastion.server))
        var web = try test.host(password: "never read")
        web.name = "web-01"
        web.address = TestServer.reachedFromAnother(port: 2224).address
        web.port = TestServer.reachedFromAnother(port: 2224).port
        web.jumpHostIDs = [bastion.id]
        let route = try Route(to: web, hosts: [bastion.id: bastion])
        let questions = TrustQuestions(answer: true)

        let error = await #expect(throws: JumpHostError.self) {
            try await test.connector.connect(along: route) { hop, key in questions.ask(hop.server, key) }
        }

        #expect(error?.jumpHost == bastion)
        #expect(
            error?.error as? ConnectError
                == .hostKeyChanged(bastion.server, trusted: trusted, presented: TestServer.hostKeyA))
        #expect(error?.description == "The host key of the jump host bastion changed. Shello didn’t connect.")
        #expect(questions.keys.isEmpty)
        #expect(try await test.hostKeys.trustedKey(of: web.server) == nil)
        #expect(test.keychain.reads == 0)
    }

    /// Each hop signs in as its own host says: a password on the jump host, the server's questions
    /// on the next, answered for that hop, a password and then a one-time code, and the SSH key on
    /// the host. The Docker servers only: CI's sshd takes keys only.
    @Test(.enabled(if: TestServer.password != nil, TestServer.noPasswords))
    func eachHopSignsInWithItsOwnMethod() async throws {
        let bastion = try test.host(password: TestServer.password)
        var inner = try test.host(password: nil, user: "shello-otp")
        inner.name = "inner"
        inner.authMethod = .keyboardInteractive
        inner.address = TestServer.reachedFromAnother(port: 2224).address
        inner.port = TestServer.reachedFromAnother(port: 2224).port
        let web = try keyHost("web-01", at: TestServer.reachedFromAnother(port: 2226), through: [bastion, inner])
        for hop in [bastion, inner, web] {
            try await test.hostKeys.trust(TestServer.hostKeyA, of: hop.server)
        }
        let route = try Route(to: web, hosts: [bastion.id: bastion, inner.id: inner])
        let answers = HopAnswers()

        let connection = try await test.connector.connect(
            along: route, askToTrust: { _, _ in false }, answer: { hop, challenge in answers.answer(hop, challenge) })

        #expect(try await connection.run("whoami").output == Array("\(TestServer.user)\n".utf8))
        #expect(answers.asked == ["inner: Password:", "inner: Verification code:"])
        // The jump host's password, read from the Keychain once.
        #expect(test.keychain.reads == 1)
        await connection.close()
    }

    /// The route's first hop drops, through a proxy that breaks it (`FaultyProxy`): the tab shows
    /// that it reconnects, then rebuilds the whole route and reattaches the same tmux session, with
    /// what ran in it. The host behind the jump host has tmux: in Docker the server on port 2222,
    /// with this Mac's sshd its port 2222.
    @Test(.enabled(TmuxTestServer.noTmux) { await TmuxTestServer.hasTmux })
    func droppedFirstHopReconnectsTheWholeRouteAndReattachesTmux() async throws {
        let session = TmuxTestServer.uniqueSessionName()
        let queries = try await TmuxTestServer.signedInConnection(port: TestServer.port, test: test)
        do {
            let proxy = try await FaultyProxy(to: 2224)
            var bastion = try test.keyHost(port: proxy.port)
            bastion.name = "bastion"
            bastion.address = "127.0.0.1"
            var web = try keyHost(
                "web-01", at: TestServer.reachedFromAnother(port: TestServer.port), through: [bastion])
            web.tmuxAutoAttach = true
            web.tmuxSessionName = session
            try await save(bastion, web)
            for hop in [bastion, web] {
                try await test.hostKeys.trust(TestServer.hostKeyA, of: hop.server)
            }
            let tabs = tabs(policy: ReconnectPolicy(delays: Array(repeating: .milliseconds(200), count: 50)))
            let tab = tabs.open(web)
            await waitUntil(timeout: .seconds(30)) { tab.state == .active }
            try #require(tab.state == .active)
            guard case .attaching(let name, _)? = tab.tmux else {
                Issue.record("The tab does not attach the tmux session: \(String(describing: tab.tmux))")
                await tabs.close(tab).value
                return
            }
            #expect(name.rawValue == session)
            let before = try await TmuxTestServer.waitForSession(session, attachedClients: 1, on: queries)
            tab.terminal.type("SHELLO_STATE=held-$((40 + 2)); echo set-$((40 + 2))\r")
            await waitUntil { tab.terminal.text.contains("set-42") }
            try #require(tab.terminal.text.contains("set-42"))

            proxy.cut()
            await waitUntil { tab.reconnecting != nil }
            #expect(tab.reconnecting != nil)
            _ = try await TmuxTestServer.waitForSession(session, attachedClients: 0, on: queries)
            proxy.restore()
            await waitUntil(timeout: .seconds(30)) { tab.state == .active && tab.connectionCount == 2 }
            try #require(tab.connectionCount == 2)
            let after = try await TmuxTestServer.waitForSession(session, attachedClients: 1, on: queries)

            #expect(after.id == before.id)
            #expect(after.created == before.created)
            #expect(tab.route?.hops.map(\.name) == ["bastion", "web-01"])
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

    // MARK: - Helpers

    private func tabs(policy: ReconnectPolicy = .standard) -> TerminalTabs<FakeTerminal> {
        TerminalTabs(
            services: TabServices(
                connector: test.connector, hosts: test.hosts, network: FakeNetworkMonitor(), reconnectPolicy: policy),
            makeTerminal: { _ in FakeTerminal() })
    }

    /// The jump host `bastion`: the test server on port 2222, which signs in with the client key.
    private func jumpHost() throws -> Host {
        var host = try test.keyHost()
        host.name = "bastion"
        return host
    }

    /// A host named `name` for the test server at `server`, as the host before it on the route
    /// reaches it, through `jumpHosts`, which signs in with the client key.
    private func keyHost(_ name: String, at server: Server, through jumpHosts: [Host] = []) throws -> Host {
        var host = try test.keyHost()
        host.name = name
        host.address = server.address
        host.port = server.port
        host.jumpHostIDs = jumpHosts.map(\.id)
        return host
    }

    private func save(_ hosts: Host...) async throws {
        for host in hosts {
            try await test.hosts.create(host)
        }
    }

    /// Trusts each host key the tab asks about while it connects, and returns the hops it asked
    /// about, in order.
    private func trustEveryHostKey(of tab: TerminalTab<FakeTerminal>) async -> [RouteHop] {
        var asked: [RouteHop] = []
        while tab.state.isConnecting {
            await waitUntil(timeout: .seconds(30)) { tab.trustQuestion != nil || !tab.state.isConnecting }
            guard let question = tab.trustQuestion else { break }
            #expect(question.key == TestServer.hostKeyA)
            asked.append(question.hop)
            tab.answerTrust(true)
        }
        return asked
    }
}

/// The user answering the server's questions for each hop: its password, then a one-time code. It
/// keeps the questions, with the hop that asked.
final class HopAnswers: Sendable {
    private let questions = Mutex<[String]>([])

    var asked: [String] { questions.withLock { $0 } }

    func answer(_ hop: Host, _ challenge: KeyboardInteractiveChallenge) -> [Secret]? {
        questions.withLock { $0 += challenge.prompts.map { "\(hop.name): \($0.text)" } }
        return challenge.prompts.map { prompt in
            prompt.text.contains("code")
                ? Secret(utf8: OneTimeCode.current()) : Secret(utf8: TestServer.password ?? "")
        }
    }
}
