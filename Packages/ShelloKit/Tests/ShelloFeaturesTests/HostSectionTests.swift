import Foundation
import ShelloModel
import Testing

@testable import ShelloFeatures

struct HostSectionTests {
    let homelab = HostGroup(name: "Homelab")
    let work = HostGroup(name: "Work")

    @Test func noHostsMakeNoSections() {
        #expect(HostSection.sections(hosts: [], groups: [homelab], tagFilter: nil).isEmpty)
    }

    @Test func favoritesComeFirstInNameOrder() {
        let hosts = [
            host("forge", favorite: true), host("media-pc"), host("nas", favorite: true), host("prod-api-01"),
        ]

        let sections = HostSection.sections(hosts: hosts, groups: [], tagFilter: nil)

        #expect(sections.first?.id == .favorites)
        #expect(sections.first?.title == "Favorites")
        #expect(sections.first?.hosts.map(\.name) == ["forge", "nas"])
    }

    @Test func recentsListTheHostsConnectedToLastNewestFirst() {
        let hosts = [
            host("forge", connected: 300), host("media-pc"), host("nas", connected: 500),
            host("prod-api-01", connected: 400),
        ]

        let recents = HostSection.sections(hosts: hosts, groups: [], tagFilter: nil).first { $0.id == .recents }

        #expect(recents?.title == "Recent")
        #expect(recents?.hosts.map(\.name) == ["nas", "prod-api-01", "forge"])
    }

    /// Favourites already sit at the top of the list.
    @Test func recentsLeaveOutFavorites() {
        let hosts = [host("forge", favorite: true, connected: 500), host("nas", connected: 400)]

        let recents = HostSection.sections(hosts: hosts, groups: [], tagFilter: nil).first { $0.id == .recents }

        #expect(recents?.hosts.map(\.name) == ["nas"])
    }

    @Test func recentsHoldTheFiveLatestHosts() {
        let hosts = (1...7).map { host("host-\($0)", connected: TimeInterval($0)) }

        let recents = HostSection.sections(hosts: hosts, groups: [], tagFilter: nil).first { $0.id == .recents }

        #expect(recents?.hosts.map(\.name) == ["host-7", "host-6", "host-5", "host-4", "host-3"])
    }

    @Test func hostsConnectedToAtTheSameTimeKeepTheirNameOrder() {
        let hosts = [host("forge", connected: 100), host("nas", connected: 100), host("prod-api-01", connected: 100)]

        let recents = HostSection.sections(hosts: hosts, groups: [], tagFilter: nil).first { $0.id == .recents }

        #expect(recents?.hosts.map(\.name) == ["forge", "nas", "prod-api-01"])
    }

    @Test func withoutConnectionsThereIsNoRecentSection() {
        let sections = HostSection.sections(hosts: [host("nas")], groups: [], tagFilter: nil)

        #expect(!sections.contains { $0.id == .recents })
    }

    @Test func eachGroupWithHostsGetsASectionInGroupOrder() {
        let hosts = [
            host("ci", group: work), host("media-pc", group: homelab), host("nas", group: homelab), host("prod-api-01"),
        ]

        let sections = HostSection.sections(hosts: hosts, groups: [homelab, work], tagFilter: nil)

        #expect(sections.map(\.title) == ["Homelab", "Work", "No Group"])
        #expect(sections.map { $0.hosts.map(\.name) } == [["media-pc", "nas"], ["ci"], ["prod-api-01"]])
    }

    @Test func groupWithoutHostsHasNoSection() {
        let sections = HostSection.sections(
            hosts: [host("nas", group: homelab)], groups: [homelab, work], tagFilter: nil)

        #expect(sections.map(\.title) == ["Homelab"])
    }

    @Test func withoutGroupSectionsTheHostsAreAllHosts() {
        let sections = HostSection.sections(hosts: [host("nas"), host("forge")], groups: [homelab], tagFilter: nil)

        #expect(sections.map(\.id) == [.ungrouped])
        #expect(sections.first?.title == "All Hosts")
    }

    /// For example while the hosts already know about a new group and the groups do not yet.
    @Test func hostInAGroupTheListDoesNotKnowIsListedWithoutAGroup() {
        let sections = HostSection.sections(hosts: [host("nas", group: work)], groups: [homelab], tagFilter: nil)

        #expect(sections.map(\.id) == [.ungrouped])
    }

    @Test func favoriteIsAlsoListedInItsGroup() {
        let sections = HostSection.sections(
            hosts: [host("nas", group: homelab, favorite: true)], groups: [homelab], tagFilter: nil)

        #expect(sections.map(\.id) == [.favorites, .group(homelab.id)])
    }

    @Test func tagFilterKeepsOnlyTheHostsWithThatTagInEverySection() {
        let production = Tag(name: "Production", color: .red)
        let hosts = [
            host("ci", group: work, tags: [production]),
            host("media-pc", group: homelab),
            host("prod-api-01", tags: [production], favorite: true),
            host("staging-web", favorite: true),
        ]

        let sections = HostSection.sections(hosts: hosts, groups: [homelab, work], tagFilter: production.id)

        #expect(sections.map(\.title) == ["Favorites", "Work", "No Group"])
        #expect(sections.map { $0.hosts.map(\.name) } == [["prod-api-01"], ["ci"], ["prod-api-01"]])
    }

    private func host(
        _ name: String, group: HostGroup? = nil, tags: [Tag] = [], favorite: Bool = false,
        connected: TimeInterval? = nil
    ) -> Host {
        Host(
            name: name, address: "\(name).lan", username: "admin", groupID: group?.id, tagIDs: Set(tags.map(\.id)),
            isFavorite: favorite, lastConnectedAt: connected.map(Date.init(timeIntervalSinceReferenceDate:)))
    }
}
