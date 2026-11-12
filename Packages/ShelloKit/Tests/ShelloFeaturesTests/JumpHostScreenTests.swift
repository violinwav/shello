import Foundation
import ShelloCore
import ShelloModel
import ShelloSSH
import ShelloStorage
import Testing

@testable import ShelloFeatures

/// The screens' jump hosts (README section 3): the host editor chooses them among the saved SSH
/// hosts, orders them without dragging too, and says what is wrong with the route under them; the
/// details show the route; deleting a host names those that jump through it; and only a route's
/// first host is reached from the device, for the Local Network question. UI tests take the screens
/// through the app.
@Suite(.timeLimit(.minutes(1)))
struct JumpHostScreenTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }
    let bastion = Host(name: "bastion", address: "bastion.example.com", username: "jump")
    let inner = Host(name: "inner", address: "10.0.0.5", username: "jump")
    let mosh = Host(name: "forge", address: "forge.lan", protocol: .mosh, username: "dev")

    init() async throws {
        test = try TestDatabase()
        for host in [bastion, inner, mosh] {
            try await test.repository.create(host)
        }
    }

    // MARK: - The editor

    /// Only saved SSH hosts are offered, not the host itself, nor one it jumps through already.
    @Test func editorOffersTheOtherSavedSSHHosts() async throws {
        let web = Host(name: "web-01", address: "10.0.1.21", username: "deploy")
        try await repository.create(web)
        let model = HostEditorModel(repository: repository, host: web)
        let observing = Task { await model.observeSavedHosts() }
        defer { observing.cancel() }
        await waitUntil { model.savedHosts.count == 4 }

        #expect(model.jumpHostCandidates.map(\.name) == ["bastion", "inner"])
        model.addJumpHost(bastion.id)
        #expect(model.jumpHostCandidates.map(\.name) == ["inner"])
    }

    @Test func chosenJumpHostsAreSavedInTheirOrder() async throws {
        let (model, observing) = try await editor()
        defer { observing.cancel() }

        model.addJumpHost(bastion.id)
        model.addJumpHost(inner.id)

        #expect(model.jumpHostsSummary == "bastion → inner")
        #expect(model.spokenJumpHostsSummary == "bastion, then inner")
        #expect(model.jumpHostsProblem == nil)
        #expect(await model.save())
        #expect(try await repository.hosts().first { $0.name == "web-01" }?.jumpHostIDs == [bastion.id, inner.id])
    }

    /// Move Up and Move Down, VoiceOver's and the row menu's, do what dragging does.
    @Test func jumpHostsMoveUpAndDownWithoutDragging() async throws {
        let (model, observing) = try await editor()
        defer { observing.cancel() }
        model.addJumpHost(bastion.id)
        model.addJumpHost(inner.id)

        model.moveJumpHost(at: 1, by: -1)
        #expect(model.draft.jumpHostIDs == [inner.id, bastion.id])
        model.moveJumpHost(at: 0, by: 1)
        #expect(model.draft.jumpHostIDs == [bastion.id, inner.id])
        // Past either end, nothing moves.
        model.moveJumpHost(at: 0, by: -1)
        model.moveJumpHost(at: 1, by: 1)
        #expect(model.draft.jumpHostIDs == [bastion.id, inner.id])

        model.moveJumpHosts(from: IndexSet(integer: 0), to: 2)
        #expect(model.draft.jumpHostIDs == [inner.id, bastion.id])
        model.removeJumpHosts(at: IndexSet(integer: 0))
        #expect(model.jumpHostsSummary == "bastion")
        model.removeJumpHosts(at: IndexSet(integer: 0))
        #expect(model.jumpHostsSummary == "None")
    }

    /// A route that comes back to the host is refused in the editor, and says how to fix it.
    @Test func routeThatReachesTheHostTwiceIsRefused() async throws {
        let web = Host(name: "web-01", address: "10.0.1.21", username: "deploy")
        try await repository.create(web)
        var looped = bastion
        looped.jumpHostIDs = [web.id]
        try await repository.update(looped)
        let (model, observing) = try await editor(for: web)
        defer { observing.cancel() }

        model.addJumpHost(bastion.id)

        let problem = "The route goes through web-01 twice. Choose jump hosts that reach each host once."
        #expect(model.jumpHostsProblem == problem)
        #expect(model.visibleProblem(for: .jumpHosts) == problem)
        #expect(await model.save() == false)
        #expect(model.firstProblemField == .jumpHosts)
        #expect(try await repository.host(id: web.id)?.jumpHostIDs == [])
    }

    @Test func routeWithMoreJumpHostsThanTheLimitIsRefused() async throws {
        let (model, observing) = try await editor()
        defer { observing.cancel() }
        var hops: [Host] = []
        for index in 1...9 {
            let hop = Host(name: "hop-\(index)", address: "hop-\(index).lan", username: "jump")
            try await repository.create(hop)
            hops.append(hop)
        }
        await waitUntil { model.savedHosts.count == 12 }

        for hop in hops.prefix(8) { model.addJumpHost(hop.id) }
        #expect(model.jumpHostsProblem == nil)
        model.addJumpHost(hops[8].id)

        #expect(
            model.jumpHostsProblem
                == "The route goes through more than 8 jump hosts. Remove some, here or from the first jump host’s.")
        #expect(await model.save() == false)
    }

    /// The first jump host's own jump hosts count, as when connecting.
    @Test func routeIncludesTheFirstJumpHostsOwnJumpHosts() async throws {
        var throughInner = bastion
        throughInner.jumpHostIDs = [inner.id]
        try await repository.update(throughInner)
        let (model, observing) = try await editor()
        defer { observing.cancel() }
        await waitUntil { model.savedHosts.first { $0.id == bastion.id }?.jumpHostIDs == [inner.id] }

        model.addJumpHost(bastion.id)

        #expect(try model.route?.get().hops.map(\.name) == ["inner", "bastion", "web-01"])
    }

    /// A jump host that was deleted stays, shown as missing, and the problem says so; saving the rest
    /// of the host keeps it, rather than connecting directly.
    @Test func deletedJumpHostIsShownAsMissingAndKept() async throws {
        let web = Host(name: "web-01", address: "10.0.1.21", username: "deploy", jumpHostIDs: [bastion.id, inner.id])
        try await repository.create(web)
        try await repository.deleteHost(id: bastion.id)
        let (model, observing) = try await editor(for: web)
        defer { observing.cancel() }

        #expect(model.jumpHosts.map(\.name) == ["Missing host", "inner"])
        #expect(model.jumpHostsSummary == "Missing host → inner")
        #expect(
            model.visibleProblem(for: .jumpHosts)
                == "One of these jump hosts was deleted. Remove it: until then, Shello doesn’t connect to this host.")
        model.draft.port = "2222"
        #expect(await model.save())
        #expect(try await repository.host(id: web.id)?.jumpHostIDs == [bastion.id, inner.id])
    }

    /// A jump host that is no SSH host any more is refused once the user changes the jump hosts.
    @Test func jumpHostThatIsNoSSHHostIsRefused() async throws {
        let web = Host(name: "web-01", address: "10.0.1.21", username: "deploy", jumpHostIDs: [mosh.id])
        try await repository.create(web)
        let (model, observing) = try await editor(for: web)
        defer { observing.cancel() }

        #expect(
            model.jumpHostsProblem
                == "forge isn’t an SSH host, so it can’t be a jump host. Remove it, or make it an SSH host.")
        // Another host's change broke the route: the rest can still be saved.
        model.draft.port = "2222"
        #expect(await model.save())
        model.addJumpHost(bastion.id)
        #expect(await model.save() == false)
    }

    @Test func editorNamesTheHostsThatJumpThroughTheHostItEdits() async throws {
        let web = Host(name: "web-01", address: "10.0.1.21", username: "deploy", jumpHostIDs: [bastion.id])
        try await repository.create(web)
        let (model, observing) = try await editor(for: bastion)
        defer { observing.cancel() }

        #expect(model.hostsJumpingThrough.map(\.name) == ["web-01"])
    }

    // MARK: - The details

    @Test func detailsShowTheRouteThroughTheJumpHosts() async throws {
        let web = Host(name: "web-01", address: "10.0.1.21", username: "deploy", jumpHostIDs: [bastion.id, inner.id])
        try await repository.create(web)
        let model = HostDetailModel(repository: repository, hostID: web.id)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await waitUntil { model.host != nil && model.routeSummary.contains("bastion") }

        #expect(model.routeSummary == "bastion → inner → web-01")
        #expect(model.spokenRouteSummary == "bastion, then inner, then web-01")
        #expect(model.routeProblem == nil)
        #expect(try model.route?.get().firstHop == bastion)

        try await repository.deleteHost(id: inner.id)
        await waitUntil { model.routeProblem != nil }

        #expect(model.routeSummary == "bastion → Missing host → web-01")
        #expect(
            model.routeProblem
                == "One of its jump hosts was deleted. Shello doesn’t connect to this host until you change its jump "
                + "hosts.")
    }

    @Test func detailsOfAHostWithoutJumpHostsSayItConnectsDirectly() async throws {
        let model = HostDetailModel(repository: repository, hostID: bastion.id)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await waitUntil { model.host != nil }

        #expect(model.routeSummary == "Direct")
        #expect(model.routeProblem == nil)
    }

    // MARK: - Deleting a jump host

    /// The confirmation names the hosts that jump through the host, which keep it as missing.
    @Test func deletionMessageNamesTheHostsThatJumpThroughIt() {
        let web = Host(name: "web-01", address: "10.0.1.21", username: "deploy")
        let db = Host(name: "db-01", address: "10.0.1.31", username: "deploy")

        #expect(JumpHostDisplay.deletionMessage(users: []) == "This removes the host from Shello.")
        #expect(
            JumpHostDisplay.deletionMessage(users: [web])
                == "This removes the host from Shello. web-01 connects through it, and keeps it as a missing jump "
                + "host: web-01 doesn’t connect until you change its jump hosts.")
        #expect(JumpHostDisplay.deletionMessage(users: [web, db]).contains("web-01 and db-01 connect through it"))
    }

    /// Many hosts are counted first, and only the first few named.
    @Test func deletionMessageCountsManyHostsAndNamesTheFirstFew() {
        let users = (1...5).map { Host(name: "web-0\($0)", address: "10.0.1.2\($0)", username: "deploy") }

        let message = JumpHostDisplay.deletionMessage(users: users)

        #expect(
            message.hasPrefix(
                "This removes the host from Shello. 5 hosts connect through it, and keep it as a missing jump host: "
                    + "they don’t connect until you change their jump hosts. They are web-01, web-02, web-03"))
        #expect(message.hasSuffix("2 others."))
        #expect(!message.contains("web-04"))
        #expect(JumpHostDisplay.deletionMessage(users: Array(users.prefix(4))).hasSuffix("1 other."))
    }

    /// The texts about a whole route name the host with the jump hosts it is reached through.
    @Test func hostIsNamedWithItsJumpHosts() {
        #expect(JumpHostDisplay.host("web-01", through: []) == "web-01")
        #expect(JumpHostDisplay.host("web-01", through: ["bastion"]) == "web-01 through bastion")
        #expect(JumpHostDisplay.host("web-01", through: ["bastion", "inner"]) == "web-01 through bastion, then inner")
    }

    @Test func hostListNamesTheHostsThatJumpThroughAHostBeforeDeletingIt() async throws {
        let web = Host(name: "web-01", address: "10.0.1.21", username: "deploy", jumpHostIDs: [inner.id])
        var throughBastion = inner
        throughBastion.jumpHostIDs = [bastion.id]
        try await repository.create(web)
        try await repository.update(throughBastion)
        let model = HostListModel(repository: repository)

        #expect(await model.hostsJumping(through: bastion).map(\.name) == ["inner", "web-01"])
        #expect(await model.hostsJumping(through: mosh).isEmpty)
    }

    // MARK: - Local Network

    /// Only the route's first host is reached from the device: a host behind a jump host never
    /// brings the explanation, whatever its address, and a local first jump host does.
    @Test @MainActor func onlyTheFirstHopIsExplainedForLocalNetworkAccess() throws {
        let defaults = TestDefaults()
        let notice = LocalNetworkNotice(defaults: defaults.defaults)
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        let behindBastion = Host(name: "db", address: "192.168.1.20", username: "admin", jumpHostIDs: [bastion.id])
        let behindNAS = Host(name: "media", address: "media.example.com", username: "admin", jumpHostIDs: [nas.id])

        #expect(!notice.explainsBeforeConnecting(to: behindBastion))
        #expect(!notice.explainsBeforeConnecting(along: try Route(to: behindBastion, hosts: [bastion.id: bastion])))
        #expect(notice.explainsBeforeConnecting(along: try Route(to: behindNAS, hosts: [nas.id: nas])))
        #expect(notice.explainsBeforeConnecting(along: try Route(to: nas, hosts: [:])))
    }

    // MARK: - The connection's marking

    /// Post-quantum only when every connection along the route is (README section 14).
    @Test func connectionIsMarkedPostQuantumOnlyWhenEveryHopIs() throws {
        let postQuantum = KeyExchange(name: "mlkem768x25519-sha256", isPostQuantum: true)
        let classical = KeyExchange(name: "curve25519-sha256", isPostQuantum: false)
        let hop = { (keyExchange: KeyExchange?) in
            RouteKeyExchange(hostName: "hop", server: Server(address: "hop.lan", port: 22), keyExchange: keyExchange)
        }

        #expect(try #require(ConnectionMarking([hop(postQuantum)])).title == "Post-Quantum Key Exchange")
        #expect(try #require(ConnectionMarking([hop(postQuantum), hop(postQuantum)])).systemImage == "lock.shield")
        #expect(try #require(ConnectionMarking([hop(postQuantum), hop(classical)])).title == "Classical Key Exchange")
        let jumpHostClassical = try #require(ConnectionMarking([hop(classical), hop(postQuantum)]))
        #expect(jumpHostClassical.title == "Classical Key Exchange on a Jump Host")
        #expect(jumpHostClassical.systemImage == "lock")
        #expect(ConnectionMarking([hop(postQuantum), hop(nil)]) == nil)
        // A jump host's key exchange that Shello doesn't know is not marked post-quantum, nor classical.
        let jumpHostUnknown = try #require(ConnectionMarking([hop(nil), hop(postQuantum)]))
        #expect(jumpHostUnknown.title == "Unknown Key Exchange on a Jump Host")
        #expect(jumpHostUnknown.systemImage == "lock")
        #expect(
            try #require(ConnectionMarking([hop(nil), hop(classical), hop(postQuantum)])).title
                == "Classical Key Exchange on a Jump Host")
    }

    // MARK: - Helpers

    /// An editor for a new host `web-01`, or for `host`, once it has read the saved hosts, and the
    /// task that follows them, which the test cancels.
    private func editor(for host: Host? = nil) async throws -> (HostEditorModel, Task<Void, Never>) {
        let model = HostEditorModel(repository: repository, host: host)
        if host == nil {
            model.draft.name = "web-01"
            model.draft.address = "10.0.1.21"
        }
        let observing = Task { await model.observeSavedHosts() }
        await waitUntil { model.savedHosts.count >= 3 }
        return (model, observing)
    }
}
