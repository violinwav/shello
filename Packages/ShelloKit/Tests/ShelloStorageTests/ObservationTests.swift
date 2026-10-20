import Foundation
import ShelloModel
import Testing

@testable import ShelloStorage

@Suite(.timeLimit(.minutes(1)))
struct ObservationTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
    }

    @Test func hostObservationSendsTheHostsThenEveryChange() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        let forge = Host(name: "forge", address: "forge.lan", username: "dev")
        try await repository.create(nas)
        var hosts = repository.observeHosts().makeAsyncIterator()
        #expect(try await hosts.next() == [nas])

        try await repository.create(forge)
        #expect(try await hosts.next() == [forge, nas])

        var renamed = nas
        renamed.name = "nas-2"
        try await repository.update(renamed)
        #expect(try await hosts.next() == [forge, renamed])

        try await repository.deleteHost(id: forge.id)
        #expect(try await hosts.next() == [renamed])
    }

    @Test func hostObservationSendsOnlyTheHostsItsQueryMatches() async throws {
        var hosts = repository.observeHosts(HostQuery(search: "prod")).makeAsyncIterator()
        #expect(try await hosts.next() == [])

        try await repository.create(Host(name: "nas", address: "nas.lan", username: "admin"))
        let prod = Host(name: "prod-db", address: "10.0.4.30", username: "postgres")
        try await repository.create(prod)

        #expect(try await hosts.next() == [prod])
    }

    @Test func groupObservationSendsTheGroupsThenEveryChange() async throws {
        let homelab = HostGroup(name: "Homelab")
        try await repository.create(homelab)
        var groups = repository.observeGroups().makeAsyncIterator()
        #expect(try await groups.next() == [homelab])

        let work = HostGroup(name: "Work")
        try await repository.create(work)
        #expect(try await groups.next() == [homelab, work])

        try await repository.deleteGroup(id: homelab.id)
        #expect(try await groups.next() == [work])
    }

    @Test func tagObservationSendsTheTagsThenEveryChange() async throws {
        var production = Tag(name: "Production", color: .red)
        try await repository.create(production)
        var tags = repository.observeTags().makeAsyncIterator()
        #expect(try await tags.next() == [production])

        production.color = .orange
        try await repository.update(production)
        #expect(try await tags.next() == [production])

        try await repository.deleteTag(id: production.id)
        #expect(try await tags.next() == [])
    }
}
