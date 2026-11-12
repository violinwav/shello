import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloStorage
import Testing

@testable import ShelloCore

/// Tabs whose hosts are behind jump hosts (README section 3), over a stand-in for the network and the
/// servers (`FakeServer`): the tab connects along the route, its progress and questions name the hop
/// they are about, it refuses a route with a missing jump host or one that repeats a host before
/// anything goes over the network, a failure at a jump host names it, and a dropped connection
/// reconnects the whole route as it is stored then. JumpHostIntegrationTests take routes against the
/// test servers.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct JumpHostTabTests {
    let hosts: TestHosts
    let test: TabTest
    let bastion: Host
    let inner: Host
    let web: Host

    init() async throws {
        hosts = try TestHosts()
        test = TabTest(hosts: hosts.repository)
        bastion = Host(name: "bastion", address: "bastion.example.com", username: "jump", authMethod: .password)
        inner = Host(name: "inner", address: "10.0.0.5", username: "jump", authMethod: .password)
        web = Host(
            name: "web-01", address: "10.0.1.21", username: "deploy", authMethod: .password,
            jumpHostIDs: [bastion.id, inner.id], keepaliveInterval: .seconds(3600))
        for host in [bastion, inner, web] {
            try await hosts.repository.create(host)
        }
    }

    static let hostKey = HostKey(algorithm: "ssh-ed25519", wireRepresentation: Data([1, 2]), fingerprint: "SHA256:AQI")

    @Test func tabConnectsAlongTheRouteAndListsEachHopsKeyExchange() async throws {
        let tab = try await test.openActiveTab(web)

        #expect(test.server.routes.map { $0.hops.map(\.name) } == [["bastion", "inner", "web-01"]])
        #expect(tab.route?.hops.map(\.name) == ["bastion", "inner", "web-01"])
        #expect(tab.currentJumpHost == nil)
        #expect(
            tab.keyExchanges == [
                RouteKeyExchange(
                    hostName: "bastion", server: bastion.server, keyExchange: FakeConnection.jumpHostKeyExchange),
                RouteKeyExchange(
                    hostName: "inner", server: inner.server, keyExchange: FakeConnection.jumpHostKeyExchange),
                RouteKeyExchange(hostName: "web-01", server: web.server, keyExchange: FakeConnection.keyExchange),
            ])
        #expect(tab.keyExchange == FakeConnection.keyExchange)
        // Each hop's steps, in order, and the tab's own host's session last.
        #expect(test.server.progress.first == RouteProgress(hop: 0, step: .connecting))
        #expect(test.server.progress.last == RouteProgress(hop: 2, step: .signingIn))
    }

    /// The trust sheet names the hop, and where it is on the way: the progress is at its step.
    @Test func trustQuestionNamesTheJumpHostItIsAbout() async throws {
        test.server.queue(.asksToTrust(Self.hostKey, hop: 1))

        let tab = test.tabs.open(web)
        await waitUntil { tab.trustQuestion != nil }

        let question = try #require(tab.trustQuestion)
        #expect(question.hop == RouteHop(name: "inner", place: .jumpHost(destination: "web-01")))
        #expect(question.server == inner.server)
        #expect(tab.currentJumpHost?.name == "inner")
        #expect(tab.state == .connecting(.verifyingHostKey))
        tab.answerTrust(true, to: question)
        await waitUntil { tab.state == .active }
        #expect(tab.currentJumpHost == nil)
    }

    /// The tab's own host, behind jump hosts, is named with the last of them, which reaches it.
    @Test func trustQuestionOfTheHostBehindJumpHostsNamesTheLastOne() async throws {
        test.server.queue(.asksToTrust(Self.hostKey))

        let tab = test.tabs.open(web)
        await waitUntil { tab.trustQuestion != nil }

        #expect(tab.trustQuestion?.hop == RouteHop(name: "web-01", place: .behindJumpHost("inner")))
        #expect(tab.currentJumpHost == nil)
        try tab.answerTrust(false, to: #require(tab.trustQuestion))
        // A tab that never connected closes, as for a host without jump hosts.
        await waitUntil { tab.state == .closed }
        #expect(test.tabs.tabs.isEmpty)
    }

    @Test func signInQuestionNamesTheJumpHostThatAsks() async throws {
        let challenge = KeyboardInteractiveChallenge(
            name: "", instruction: "", prompts: [KeyboardInteractivePrompt(text: "Password:", showsAnswer: false)])
        test.server.queue(.asksToSignIn(challenge, hop: 0))

        let tab = test.tabs.open(web)
        await waitUntil { tab.signInQuestion != nil }

        #expect(tab.signInQuestion?.hop == RouteHop(name: "bastion", place: .jumpHost(destination: "web-01")))
        #expect(tab.signInQuestion?.server == bastion.server)
        #expect(tab.currentJumpHost?.name == "bastion")
        #expect(tab.state == .connecting(.signingIn))
        tab.answerSignIn([Secret(utf8: "jump-password")])
        await waitUntil { tab.state == .active }
    }

    /// A host without jump hosts is its own route: its questions say nothing of hops.
    @Test func hostWithoutJumpHostsConnectsDirectly() async throws {
        test.server.queue(.asksToTrust(Self.hostKey))

        let tab = test.tabs.open(bastion)
        await waitUntil { tab.trustQuestion != nil }

        #expect(tab.trustQuestion?.hop == RouteHop(name: "bastion", place: .direct))
        #expect(test.server.routes.last?.hops == [bastion])
        try tab.answerTrust(true, to: #require(tab.trustQuestion))
        await waitUntil { tab.state == .active }
        #expect(tab.keyExchanges.map(\.hostName) == ["bastion"])
    }

    // MARK: - Each sheet answers its own question

    /// A new route asks to trust each hop's host key in turn. The first sheet goes a moment after
    /// the user trusted bastion's key, and on a fast connection the tab already asks about web-01's
    /// as SwiftUI ends the dismissal by setting the sheet's item to nil. That dismissal, and a tap on
    /// the sheet as it goes, are about bastion's question: web-01's waits for its own sheet.
    @Test func goingTrustSheetLeavesTheNextHopsQuestionToItsOwnSheet() async throws {
        test.server.queue(.asks([.trust(Self.hostKey, hop: 0), .trust(Self.hostKey)]))
        let tab = test.tabs.open(web)
        await waitUntil { tab.trustQuestion != nil }
        let first = try #require(tab.trustQuestion)
        #expect(first.hop.name == "bastion")

        tab.answerTrust(true, to: first)
        await waitUntil { tab.trustQuestion != nil }
        let second = try #require(tab.trustQuestion)
        #expect(second.hop.name == "web-01")
        tab.dismissPrompt(.trust(first))
        tab.answerTrust(false, to: first)
        tab.answerTrust(true, to: first)

        #expect(tab.trustQuestion == second)
        #expect(tab.prompt == .trust(second))
        #expect(tab.state == .connecting(.verifyingHostKey))
        tab.answerTrust(true, to: second)
        await waitUntil { tab.state == .active }
        #expect(test.tabs.tabs.map(\.id) == [tab.id])
    }

    /// The sign-in sheet stays while the route signs in, and gives way to the trust sheet when the
    /// next hop's host key is new: its dismissal then, or its Cancel as it goes, leaves that
    /// question to the trust sheet.
    @Test func goingSignInSheetLeavesTheNextHopsQuestionToItsOwnSheet() async throws {
        let challenge = KeyboardInteractiveChallenge(
            name: "", instruction: "", prompts: [KeyboardInteractivePrompt(text: "Password:", showsAnswer: false)])
        test.server.queue(.asks([.signIn(challenge, hop: 0), .trust(Self.hostKey)]))
        let tab = test.tabs.open(web)
        await waitUntil { tab.signInQuestion != nil }

        tab.answerSignIn([Secret(utf8: "jump-password")])
        await waitUntil { tab.trustQuestion != nil }
        let question = try #require(tab.trustQuestion)
        tab.dismissPrompt(.signIn)

        #expect(tab.prompt == .trust(question))
        tab.answerTrust(true, to: question)
        await waitUntil { tab.state == .active }
        #expect(test.tabs.tabs.map(\.id) == [tab.id])
    }

    /// Replacing bastion's changed key connects again, which finds web-01's key changed too. The
    /// first block sheet goes once its key was replaced, and its dismissal leaves web-01's block to
    /// its own sheet, whose dismissal closes the tab, which never connected.
    @Test func goingBlockSheetLeavesTheNextHopsBlockToItsOwnSheet() async throws {
        let trusted = TrustedHostKey(key: Self.hostKey, trustedAt: .now)
        let presented = HostKey(algorithm: "ssh-ed25519", wireRepresentation: Data([3]), fingerprint: "SHA256:Aw")
        test.server.queue(
            .failsAt(hop: 0, ConnectError.hostKeyChanged(bastion.server, trusted: trusted, presented: presented)),
            .failsAt(hop: 2, ConnectError.hostKeyChanged(web.server, trusted: trusted, presented: presented)))
        let tab = test.tabs.open(web)
        await waitUntil { tab.hostKeyChange != nil }
        let first = try #require(tab.hostKeyChange)

        await tab.replaceTrustedHostKey()
        await waitUntil { tab.hostKeyChange != nil }
        let second = try #require(tab.hostKeyChange)
        #expect(second.hop.name == "web-01")
        tab.hostKeyChangeDismissed(first)

        #expect(tab.hostKeyChange == second)
        #expect(test.tabs.tabs.map(\.id) == [tab.id])
        tab.hostKeyChangeDismissed(second)
        #expect(tab.state == .closed)
        #expect(test.tabs.tabs.isEmpty)
    }

    // MARK: - Refused routes

    /// A deleted jump host stays in the list, and connecting fails, saying so: nothing goes over the
    /// network, not even to the other jump host.
    @Test func missingJumpHostRefusesToConnectAndSaysWhy() async throws {
        try await hosts.repository.deleteHost(id: inner.id)

        let tab = test.tabs.open(web)
        await waitUntil { !tab.state.isConnecting }

        #expect(tab.state == .disconnected(RouteError.missingJumpHost(of: "web-01").description))
        #expect(test.server.tries == 0)
    }

    @Test func routeThatReachesAHostTwiceRefusesToConnect() async throws {
        var looped = bastion
        looped.jumpHostIDs = [web.id]
        try await hosts.repository.update(looped)

        let tab = test.tabs.open(web)
        await waitUntil { !tab.state.isConnecting }

        #expect(tab.state == .disconnected(RouteError.repeatsHost("web-01").description))
        #expect(test.server.tries == 0)
    }

    /// Without the saved hosts to look them up in, jump hosts are missing too: never left out.
    @Test func jumpHostsThatCannotBeLookedUpAreMissing() async throws {
        let test = TabTest()

        let tab = test.tabs.open(web)
        await waitUntil { !tab.state.isConnecting }

        #expect(tab.state == .disconnected(RouteError.missingJumpHost(of: "web-01").description))
        #expect(test.server.tries == 0)
    }

    // MARK: - Failures at a jump host

    @Test func failureAtAJumpHostNamesIt() async throws {
        test.server.queue(.failsAt(hop: 0, SSHError.unreachable("connection refused")))

        let tab = test.tabs.open(web)
        await waitUntil { !tab.state.isConnecting }

        #expect(
            tab.state
                == .disconnected(
                    "Couldn’t connect to the jump host bastion. The server can’t be reached: connection refused."))
    }

    /// A changed host key at a jump host blocks the route there, and the block sheet names it.
    @Test func changedHostKeyAtAJumpHostNamesIt() async throws {
        let trusted = TrustedHostKey(key: Self.hostKey, trustedAt: .now)
        let presented = HostKey(algorithm: "ssh-ed25519", wireRepresentation: Data([3]), fingerprint: "SHA256:Aw")
        test.server.queue(
            .failsAt(hop: 1, ConnectError.hostKeyChanged(inner.server, trusted: trusted, presented: presented)))

        let tab = test.tabs.open(web)
        await waitUntil { !tab.state.isConnecting }

        #expect(tab.state == .disconnected("The host key of the jump host inner changed."))
        let change = try #require(tab.hostKeyChange)
        #expect(change.hop == RouteHop(name: "inner", place: .jumpHost(destination: "web-01")))
        #expect(change.server == inner.server)
        #expect(change.presented == presented)
    }

    // MARK: - Reconnecting

    /// Any hop dropping ends the tab's connection, which is the whole route: the tab reconnects it
    /// from the first hop, with the jump hosts as they are stored then.
    @Test func droppedRouteReconnectsTheWholeRouteAsItIsStoredNow() async throws {
        let tab = try await test.openActiveTab(web)
        let first = try #require(test.server.lastConnection)
        var direct = web
        direct.jumpHostIDs = [inner.id]
        try await hosts.repository.update(direct)

        first.lose()
        await waitUntil { tab.state == .active && tab.connectionCount == 2 }

        #expect(first.isClosed)
        #expect(
            test.server.routes.map { $0.hops.map(\.name) } == [["bastion", "inner", "web-01"], ["inner", "web-01"]])
    }

    /// A jump host that is away on a reconnect is worth trying again, as the tab's own host is.
    @Test func unreachableJumpHostOnAReconnectIsTriedAgain() async throws {
        let tab = try await test.openActiveTab(web)
        test.server.queue(.failsAt(hop: 0, SSHError.unreachable("connection refused")))

        test.server.lastConnection?.lose()
        await waitUntil { tab.state == .active && tab.connectionCount == 2 }

        #expect(test.server.tries == 3)
        #expect(test.sleep.durations.contains(TabTest.policy.delays[0]))
    }
}

/// A database of hosts of its own, in a temporary directory, for the routes of the tabs' hosts.
final class TestHosts: Sendable {
    let repository: HostRepository
    private let directory = URL.temporaryDirectory.appending(path: "ShelloCoreTests-\(UUID().uuidString)")

    init() throws {
        repository = HostRepository(try AppDatabase(directory: directory))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
