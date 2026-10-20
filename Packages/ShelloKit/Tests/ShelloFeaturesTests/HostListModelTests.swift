import Foundation
import ShelloModel
import ShelloStorage
import Testing

@testable import ShelloFeatures

@Suite(.timeLimit(.minutes(1)))
struct HostListModelTests {
    let test: TestDatabase
    let model: HostListModel
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
        model = HostListModel(repository: test.repository)
    }

    @Test func listsTheStoredHostsByGroupWithTheirTags() async throws {
        let homelab = HostGroup(name: "Homelab")
        let staging = Tag(name: "Staging", color: .purple)
        try await repository.create(homelab)
        try await repository.create(staging)
        let nas = Host(name: "nas", address: "nas.lan", username: "admin", groupID: homelab.id, tagIDs: [staging.id])
        try await repository.create(nas)
        try await repository.create(Host(name: "prod-api-01", address: "10.0.4.21", username: "deploy"))

        let observing = observe()
        defer { observing.cancel() }
        await waitUntil { model.hosts.count == 2 && model.groups.count == 1 && model.tags.count == 1 }

        #expect(model.sections.map(\.title) == ["Homelab", "No Group"])
        #expect(model.sections.map { $0.hosts.map(\.name) } == [["nas"], ["prod-api-01"]])
        #expect(model.tags(of: nas).map(\.name) == ["Staging"])
    }

    @Test func listUpdatesLiveAsHostsAreAddedChangedAndDeleted() async throws {
        let observing = observe()
        defer { observing.cancel() }
        await waitUntil { model.hasLoaded }
        #expect(model.emptyState == .noHosts)

        var nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        await waitUntil { model.hosts.map(\.name) == ["nas"] }

        nas.name = "nas-2"
        try await repository.update(nas)
        await waitUntil { model.hosts.map(\.name) == ["nas-2"] }

        try await repository.deleteHost(id: nas.id)
        await waitUntil { model.hosts.isEmpty }
        #expect(model.emptyState == .noHosts)
    }

    @Test(arguments: [
        ("prod", ["prod-api-01"]),
        ("10.0.4", ["prod-api-01"]),
        ("postgres", ["db"]),
        ("staging", ["nas"]),
        ("prod 10.0.4", ["prod-api-01"]),
    ])
    func searchMatchesNamesAddressesUsersAndTags(_ search: String, matches: [String]) async throws {
        let staging = Tag(name: "Staging", color: .purple)
        try await repository.create(staging)
        try await repository.create(Host(name: "prod-api-01", address: "10.0.4.21", username: "deploy"))
        try await repository.create(Host(name: "db", address: "db.internal", username: "postgres"))
        try await repository.create(Host(name: "nas", address: "nas.lan", username: "admin", tagIDs: [staging.id]))

        let observing = observe(search: search)
        defer { observing.cancel() }
        await waitUntil { model.hasLoaded }

        #expect(model.hosts.map(\.name) == matches)
    }

    @Test func searchThatFindsNothingSaysSo() async throws {
        try await repository.create(Host(name: "nas", address: "nas.lan", username: "admin"))

        let observing = observe(search: "forge")
        defer { observing.cancel() }
        await waitUntil { model.hasLoaded }

        #expect(model.emptyState == .noSearchResults("forge"))
    }

    @Test func tagFilterListsOnlyTheHostsWithThatTag() async throws {
        let production = Tag(name: "Production", color: .red)
        try await repository.create(production)
        try await repository.create(
            Host(name: "prod-api-01", address: "10.0.4.21", username: "deploy", tagIDs: [production.id]))
        try await repository.create(Host(name: "nas", address: "nas.lan", username: "admin"))
        let observing = observe()
        defer { observing.cancel() }
        await waitUntil { model.hosts.count == 2 && model.tags.count == 1 }

        model.tagFilter = production.id

        #expect(model.sections.flatMap(\.hosts).map(\.name) == ["prod-api-01"])
    }

    @Test func tagFilterWithNoMatchingHostSaysSo() async throws {
        let production = Tag(name: "Production", color: .red)
        try await repository.create(production)
        try await repository.create(Host(name: "nas", address: "nas.lan", username: "admin"))
        let observing = observe()
        defer { observing.cancel() }
        await waitUntil { model.hosts.count == 1 && model.tags.count == 1 }

        model.tagFilter = production.id

        #expect(model.emptyState == .noHostsWithTag("Production"))
    }

    @Test func tagFilterEndsWhenItsTagIsDeleted() async throws {
        let production = Tag(name: "Production", color: .red)
        try await repository.create(production)
        try await repository.create(Host(name: "nas", address: "nas.lan", username: "admin"))
        let observing = observe()
        defer { observing.cancel() }
        await waitUntil { model.hosts.count == 1 && model.tags.count == 1 }
        model.tagFilter = production.id

        try await repository.deleteTag(id: production.id)
        await waitUntil { model.tags.isEmpty }

        #expect(model.activeTagFilter == nil)
        #expect(model.sections.flatMap(\.hosts).map(\.name) == ["nas"])
    }

    @Test func favoritingAHostListsItWithTheFavorites() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        let observing = observe()
        defer { observing.cancel() }
        await waitUntil { model.hosts.count == 1 }

        await model.setFavorite(true, for: nas)
        await waitUntil { model.sections.first?.id == .favorites }

        #expect(model.sections.first?.hosts.map(\.name) == ["nas"])
        #expect(try await repository.host(id: nas.id)?.isFavorite == true)
    }

    @Test func unfavoritingAHostTakesItOutOfTheFavorites() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin", isFavorite: true)
        try await repository.create(nas)
        let observing = observe()
        defer { observing.cancel() }
        await waitUntil { model.sections.first?.id == .favorites }

        await model.setFavorite(false, for: nas)
        await waitUntil { model.sections.map(\.id) == [.ungrouped] }

        #expect(try await repository.host(id: nas.id)?.isFavorite == false)
    }

    /// The list changes only the favourite flag, on the host as it is now, so it never undoes a
    /// change made since the list last read the host.
    @Test func favoritingKeepsChangesTheListHasNotSeenYet() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        var renamed = nas
        renamed.name = "nas-2"
        try await repository.update(renamed)

        await model.setFavorite(true, for: nas)

        let stored = try #require(try await repository.host(id: nas.id))
        #expect(stored.name == "nas-2")
        #expect(stored.isFavorite)
    }

    @Test func failingToFavoriteReportsTheError() async {
        let deleted = Host(name: "nas", address: "nas.lan", username: "admin")

        #expect(await model.setFavorite(true, for: deleted) == false)
        #expect(model.actionError != nil)
    }

    @Test func deletingAHostTakesItOffTheList() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        try await repository.create(Host(name: "forge", address: "forge.lan", username: "dev"))
        let observing = observe()
        defer { observing.cancel() }
        await waitUntil { model.hosts.count == 2 }

        #expect(await model.delete(nas))
        await waitUntil { model.hosts.count == 1 }

        #expect(model.hosts.map(\.name) == ["forge"])
        #expect(try await repository.host(id: nas.id) == nil)
        #expect(model.actionError == nil)
    }

    @Test func failingToDeleteReportsTheError() async throws {
        #expect(await model.delete(Host(name: "nas", address: "nas.lan", username: "admin")) == false)

        #expect(model.actionError != nil)
    }

    /// Observes the way the list screen does, until the returned task is cancelled.
    private func observe(search: String = "") -> Task<Void, Never> {
        Task {
            async let groupsAndTags: Void = model.observeGroupsAndTags()
            async let hosts: Void = model.observeHosts(matching: search)
            _ = await (groupsAndTags, hosts)
        }
    }
}
