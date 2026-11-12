import Foundation
import Testing

@testable import ShelloModel

/// The route to a host through its jump hosts (README section 3), as OpenSSH's `ProxyJump` goes:
/// the first jump host's own jump hosts count, the others' do not, and Shello refuses a route that
/// reaches a host twice, is too long, or has a jump host that is missing or not an SSH host.
struct RouteTests {
    @Test func hostWithoutJumpHostsIsReachedDirectly() throws {
        let host = Self.host("web-01")

        let route = try Route(to: host, hosts: [:])

        #expect(route.hops == [host])
        #expect(route.firstHop == host)
        #expect(route.host == host)
        #expect(route.jumpHosts.isEmpty)
    }

    @Test func jumpHostsComeFirstInTheirOrder() throws {
        let bastion = Self.host("bastion")
        let inner = Self.host("inner")
        let web = Self.host("web-01", through: [bastion, inner])

        let route = try Route(to: web, hosts: Self.saved(bastion, inner, web))

        #expect(route.hops.map(\.name) == ["bastion", "inner", "web-01"])
        #expect(Array(route.jumpHosts) == [bastion, inner])
        #expect(route.firstHop == bastion)
    }

    /// OpenSSH applies a first hop's own `ProxyJump`, so the route to the first jump host comes first.
    @Test func firstJumpHostsOwnJumpHostsCome() throws {
        let gateway = Self.host("gateway")
        let bastion = Self.host("bastion", through: [gateway])
        let web = Self.host("web-01", through: [bastion])

        let route = try Route(to: web, hosts: Self.saved(gateway, bastion, web))

        #expect(route.hops.map(\.name) == ["gateway", "bastion", "web-01"])
    }

    /// The hops after the first already lead to a jump host, so its own jump hosts do not count.
    @Test func laterJumpHostsOwnJumpHostsDoNot() throws {
        let gateway = Self.host("gateway")
        let bastion = Self.host("bastion")
        let inner = Self.host("inner", through: [gateway])
        let web = Self.host("web-01", through: [bastion, inner])

        let route = try Route(to: web, hosts: Self.saved(gateway, bastion, inner, web))

        #expect(route.hops.map(\.name) == ["bastion", "inner", "web-01"])
    }

    /// The host as given, such as the host editor's draft, rather than as it is saved.
    @Test func hostIsTakenAsGiven() throws {
        let bastion = Self.host("bastion")
        let saved = Self.host("web-01")
        var draft = saved
        draft.jumpHostIDs = [bastion.id]

        let route = try Route(to: draft, hosts: Self.saved(bastion, saved))

        #expect(route.hops.map(\.name) == ["bastion", "web-01"])
    }

    // MARK: - Refused routes

    @Test func hostThatJumpsThroughItselfIsRefused() {
        var web = Self.host("web-01")
        web.jumpHostIDs = [web.id]

        // Saved or not yet, as in the editor of a new host.
        for hosts in [Self.saved(web), [:]] {
            #expect(throws: RouteError.repeatsHost("web-01")) { try Route(to: web, hosts: hosts) }
        }
    }

    @Test func jumpHostListedTwiceIsRefused() {
        let bastion = Self.host("bastion")
        let inner = Self.host("inner")
        let web = Self.host("web-01", through: [bastion, inner, bastion])

        #expect(throws: RouteError.repeatsHost("bastion")) {
            try Route(to: web, hosts: Self.saved(bastion, inner, web))
        }
    }

    /// A first jump host whose route comes back to the host: a cycle, which never ends.
    @Test func cycleThroughTheFirstJumpHostsIsRefused() {
        let webID = UUID()
        let gateway = Self.host("gateway", jumpHostIDs: [webID])
        let bastion = Self.host("bastion", through: [gateway])
        let web = Host(id: webID, name: "web-01", address: "web-01.lan", username: "admin", jumpHostIDs: [bastion.id])

        #expect(throws: RouteError.repeatsHost("web-01")) {
            try Route(to: web, hosts: Self.saved(gateway, bastion, web))
        }
    }

    /// A later jump host that the first one's route already passes through.
    @Test func jumpHostThatTheFirstOnesRoutePassesIsRefused() {
        let gateway = Self.host("gateway")
        let bastion = Self.host("bastion", through: [gateway])
        let web = Self.host("web-01", through: [bastion, gateway])

        #expect(throws: RouteError.repeatsHost("gateway")) {
            try Route(to: web, hosts: Self.saved(gateway, bastion, web))
        }
    }

    @Test func eightJumpHostsAreAllowedAndNineAreNot() throws {
        let jumpHosts = (1...9).map { Self.host("hop-\($0)") }
        let eight = Self.host("web-01", through: Array(jumpHosts.prefix(8)))
        let nine = Self.host("web-02", through: jumpHosts)

        #expect(Route.maximumJumpHosts == 8)
        #expect(try Route(to: eight, hosts: Self.saved(jumpHosts + [eight])).jumpHosts.count == 8)
        #expect(throws: RouteError.tooManyJumpHosts) { try Route(to: nine, hosts: Self.saved(jumpHosts + [nine])) }
    }

    /// The limit counts the hops of the whole route, the first jump host's own included.
    @Test func longRouteThroughTheFirstJumpHostsIsRefused() throws {
        var hosts: [Host] = [Self.host("hop-0")]
        for index in 1...9 {
            hosts.append(Self.host("hop-\(index)", through: [hosts[index - 1]]))
        }

        #expect(throws: RouteError.tooManyJumpHosts) { try Route(to: hosts[9], hosts: Self.saved(hosts)) }
        #expect(try Route(to: hosts[8], hosts: Self.saved(hosts)).jumpHosts.count == 8)
    }

    /// A deleted jump host stays in the list: the host is not reached directly, nor through the
    /// others alone.
    @Test func missingJumpHostIsRefusedAndNamesTheHostThatListsIt() {
        let bastion = Self.host("bastion")
        let web = Self.host("web-01", jumpHostIDs: [UUID(), bastion.id])

        #expect(throws: RouteError.missingJumpHost(of: "web-01")) {
            try Route(to: web, hosts: Self.saved(bastion, web))
        }
    }

    @Test func missingJumpHostOfTheFirstJumpHostIsRefused() {
        let bastion = Self.host("bastion", jumpHostIDs: [UUID()])
        let web = Self.host("web-01", through: [bastion])

        #expect(throws: RouteError.missingJumpHost(of: "bastion")) {
            try Route(to: web, hosts: Self.saved(bastion, web))
        }
    }

    @Test(arguments: [HostProtocol.mosh, .vnc])
    func jumpHostThatIsNotAnSSHHostIsRefused(_ hostProtocol: HostProtocol) {
        var bastion = Self.host("bastion")
        bastion.protocol = hostProtocol
        let web = Self.host("web-01", through: [bastion])

        #expect(throws: RouteError.notSSH("bastion")) { try Route(to: web, hosts: Self.saved(bastion, web)) }
    }

    /// The host itself may be a Mosh host, which starts over SSH.
    @Test func moshHostCanHaveJumpHosts() throws {
        let bastion = Self.host("bastion")
        var web = Self.host("web-01", through: [bastion])
        web.protocol = .mosh

        #expect(try Route(to: web, hosts: Self.saved(bastion, web)).hops.count == 2)
    }

    /// Each refusal says what to change, in few enough words for the terminal's status bar.
    @Test func refusalsSayWhatToChange() {
        #expect(
            RouteError.missingJumpHost(of: "web-01").description
                == "One of web-01’s jump hosts was deleted. Change them to connect.")
        #expect(
            RouteError.repeatsHost("bastion").description
                == "The route goes through bastion twice. Change the jump hosts.")
        #expect(
            RouteError.tooManyJumpHosts.description
                == "The route goes through more than 8 jump hosts. Use 8 or fewer.")
        #expect(
            RouteError.notSSH("media-pc").description
                == "media-pc isn’t an SSH host, so it can’t be a jump host. Change the jump hosts.")
    }

    // MARK: - Hosts that jump through a host

    @Test func hostsThatJumpThroughAHostAreThoseWhoseRoutesPassIt() {
        let gateway = Self.host("gateway")
        let bastion = Self.host("bastion", through: [gateway])
        let web = Self.host("web-01", through: [bastion])
        let db = Self.host("db-01", through: [bastion])
        // A later jump host's own jump hosts are not on the route.
        let inner = Self.host("inner", through: [gateway])
        let api = Self.host("api-01", jumpHostIDs: [UUID(), inner.id])
        let direct = Self.host("nas")
        let hosts = [gateway, bastion, web, db, inner, api, direct]

        #expect(
            Route.hosts(jumpingThrough: gateway.id, among: hosts).map(\.name) == [
                "bastion", "web-01", "db-01", "inner",
            ])
        #expect(Route.hosts(jumpingThrough: bastion.id, among: hosts).map(\.name) == ["web-01", "db-01"])
        #expect(Route.hosts(jumpingThrough: inner.id, among: hosts).map(\.name) == ["api-01"])
        #expect(Route.hosts(jumpingThrough: direct.id, among: hosts).isEmpty)
    }

    /// A cycle among the saved hosts does not keep the search going.
    @Test func hostsThatJumpThroughAHostEndOnACycle() {
        let firstID = UUID()
        let second = Self.host("second", jumpHostIDs: [firstID])
        let first = Host(id: firstID, name: "first", address: "first.lan", username: "admin", jumpHostIDs: [second.id])

        #expect(Route.hosts(jumpingThrough: UUID(), among: [first, second]).isEmpty)
        #expect(Route.hosts(jumpingThrough: second.id, among: [first, second]).map(\.name) == ["first"])
    }

    // MARK: - Helpers

    private static func host(_ name: String, through jumpHosts: [Host] = []) -> Host {
        host(name, jumpHostIDs: jumpHosts.map(\.id))
    }

    private static func host(_ name: String, jumpHostIDs: [Host.ID]) -> Host {
        Host(name: name, address: "\(name).lan", username: "admin", jumpHostIDs: jumpHostIDs)
    }

    private static func saved(_ hosts: Host...) -> [Host.ID: Host] {
        saved(hosts)
    }

    private static func saved(_ hosts: [Host]) -> [Host.ID: Host] {
        Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
    }
}
