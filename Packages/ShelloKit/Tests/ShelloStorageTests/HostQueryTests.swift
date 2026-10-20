import Foundation
import ShelloModel
import Testing

@testable import ShelloStorage

struct HostQueryTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
    }

    // MARK: - Search

    /// Four hosts, each findable through a different field.
    private func createSearchableHosts() async throws {
        let production = Tag(name: "Production", color: .red)
        let homelab = Tag(name: "Homelab", color: .blue)
        try await repository.create(production)
        try await repository.create(homelab)
        let hosts = [
            Host(name: "prod-api-01", address: "10.0.4.21", username: "deploy", tagIDs: [production.id]),
            Host(name: "forge", address: "forge.lan", username: "dev", tagIDs: [homelab.id]),
            Host(name: "nas", address: "nas.lan", username: "admin"),
            Host(name: "Zürich gateway", address: "gw.zrh.example.com", username: "ünal"),
        ]
        for host in hosts {
            try await repository.create(host)
        }
    }

    @Test(arguments: [
        ("PROD-API", "prod-api-01"),  // name
        ("FORGE.LAN", "forge"),  // address
        ("DePloy", "prod-api-01"),  // username
        ("homelab", "forge"),  // tag name
        ("ZÜRICH", "Zürich gateway"),  // name, beyond ASCII
        ("ÜNAL", "Zürich gateway"),  // username, beyond ASCII
    ])
    func searchMatchesNameAddressUsernameAndTagIgnoringCase(_ search: String, _ name: String) async throws {
        try await createSearchableHosts()

        let found = try await repository.hosts(HostQuery(search: search))

        #expect(found.map(\.name) == [name])
    }

    @Test func searchWithoutAMatchFindsNothing() async throws {
        try await createSearchableHosts()

        #expect(try await repository.hosts(HostQuery(search: "staging")).isEmpty)
    }

    @Test(arguments: ["", "   "])
    func emptySearchFindsEveryHost(_ search: String) async throws {
        try await createSearchableHosts()

        let found = try await repository.hosts(HostQuery(search: search))

        #expect(found.map(\.name) == ["forge", "nas", "prod-api-01", "Zürich gateway"])
    }

    @Test func everyWordOfASearchMustMatch() async throws {
        try await createSearchableHosts()

        #expect(try await repository.hosts(HostQuery(search: "deploy production")).map(\.name) == ["prod-api-01"])
        #expect(try await repository.hosts(HostQuery(search: "deploy homelab")).isEmpty)
    }

    @Test(arguments: ["%", "_", "*"])
    func wildcardCharactersAreSearchedForLiterally(_ search: String) async throws {
        try await createSearchableHosts()

        #expect(try await repository.hosts(HostQuery(search: search)).isEmpty)
    }

    @Test func searchLeavesDeletedHostsOut() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)
        try await repository.deleteHost(id: host.id)

        #expect(try await repository.hosts(HostQuery(search: "nas")).isEmpty)
    }

    // MARK: - Order

    @Test func nameOrderIgnoresCaseAndSortsNumbersByValue() async throws {
        for name in ["web10", "Web2", "api"] {
            try await repository.create(Host(name: name, address: "\(name).lan", username: "deploy"))
        }

        let found = try await repository.hosts(HostQuery(order: .name))

        #expect(found.map(\.name) == ["api", "Web2", "web10"])
    }

    @Test func hostsWithTheSameNameAreOrderedByUsername() async throws {
        try await repository.create(Host(name: "prod", address: "prod.lan", username: "root"))
        try await repository.create(Host(name: "prod", address: "prod.lan", username: "deploy"))

        let found = try await repository.hosts(HostQuery(order: .name))

        #expect(found.map(\.username) == ["deploy", "root"])
    }

    @Test func favoritesOrderPutsFavoritesFirstThenSortsByName() async throws {
        let hosts = [
            Host(name: "forge", address: "forge.lan", username: "dev"),
            Host(name: "nas", address: "nas.lan", username: "admin", isFavorite: true),
            Host(name: "api", address: "api.lan", username: "deploy"),
            Host(name: "media-pc", address: "10.0.0.40", username: "florian", isFavorite: true),
        ]
        for host in hosts {
            try await repository.create(host)
        }

        let found = try await repository.hosts(HostQuery(order: .favorites))

        #expect(found.map(\.name) == ["media-pc", "nas", "api", "forge"])
    }

    @Test func recentsOrderPutsTheLastConnectedFirstAndNeverConnectedLast() async throws {
        let hosts = [
            Host(name: "nas", address: "nas.lan", username: "admin"),
            Host(
                name: "forge", address: "forge.lan", username: "dev",
                lastConnectedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)),
            Host(name: "api", address: "api.lan", username: "deploy"),
            Host(
                name: "media-pc", address: "10.0.0.40", username: "florian",
                lastConnectedAt: Date(timeIntervalSinceReferenceDate: 800_000_900)),
        ]
        for host in hosts {
            try await repository.create(host)
        }

        let found = try await repository.hosts(HostQuery(order: .recents))

        #expect(found.map(\.name) == ["media-pc", "forge", "api", "nas"])
    }
}
