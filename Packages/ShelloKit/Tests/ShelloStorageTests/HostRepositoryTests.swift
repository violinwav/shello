import Foundation
import GRDB
import ShelloModel
import Testing

@testable import ShelloStorage

struct HostRepositoryTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
    }

    // MARK: - Round trips

    @Test func everyHostFieldRoundTrips() async throws {
        let group = HostGroup(name: "Homelab")
        let production = Tag(name: "Production", color: .red)
        let staging = Tag(name: "Staging", color: .purple)
        try await repository.create(group)
        try await repository.create(production)
        try await repository.create(staging)
        // Every field differs from its default, so a field the database drops shows up.
        let host = Host(
            name: "prod-api-01",
            address: "2001:db8::21",
            port: 2222,
            protocol: .mosh,
            username: "deploy",
            authMethod: .keyboardInteractive,
            sshKeyID: UUID(),
            groupID: group.id,
            tagIDs: [production.id, staging.id],
            notes: "Primary API server in Zürich.\nAsk before rebooting.",
            startupCommand: "cd /srv",
            tmuxAutoAttach: true,
            tmuxSessionName: "deploy-1",
            terminalType: "xterm",
            keepaliveInterval: .seconds(45),
            connectTimeout: .milliseconds(7_500),
            isFavorite: true,
            lastConnectedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456)
        )

        try await repository.create(host)

        #expect(try await repository.host(id: host.id) == host)
        #expect(try await repository.hosts() == [host])
    }

    @Test(arguments: HostProtocol.allCases)
    func everyProtocolRoundTrips(_ hostProtocol: HostProtocol) async throws {
        let host = Host(name: "media-pc", address: "10.0.0.40", protocol: hostProtocol, username: "florian")

        try await repository.create(host)

        #expect(try await repository.host(id: host.id) == host)
    }

    @Test(arguments: AuthMethod.allCases)
    func everyAuthMethodRoundTrips(_ authMethod: AuthMethod) async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin", authMethod: authMethod)

        try await repository.create(host)

        #expect(try await repository.host(id: host.id) == host)
    }

    @Test(arguments: Tag.Color.allCases)
    func everyTagColorRoundTrips(_ color: Tag.Color) async throws {
        let tag = Tag(name: "Homelab", color: color)

        try await repository.create(tag)

        #expect(try await repository.tags() == [tag])
    }

    @Test func groupsAndTagsComeBackSortedByName() async throws {
        let groups = [HostGroup(name: "Work"), HostGroup(name: "Homelab")]
        let tags = [Tag(name: "Staging", color: .purple), Tag(name: "production", color: .red)]
        for group in groups { try await repository.create(group) }
        for tag in tags { try await repository.create(tag) }

        #expect(try await repository.groups().map(\.name) == ["Homelab", "Work"])
        #expect(try await repository.tags().map(\.name) == ["production", "Staging"])
    }

    @Test func unknownHostIsNil() async throws {
        #expect(try await repository.host(id: UUID()) == nil)
    }

    /// The database stores durations as whole milliseconds, so the longest one it can hold is
    /// `Int64.max` of them. A longer one is cut to that instead of crashing.
    @Test func overlongDurationIsStoredAsTheLongestTheDatabaseHolds() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin", keepaliveInterval: .seconds(Int64.max))

        try await repository.create(host)

        #expect(try await repository.host(id: host.id)?.keepaliveInterval == .milliseconds(Int64.max))
    }

    /// For example a protocol a newer version of Shello added.
    @Test func storedValueThisVersionDoesNotKnowFailsToReadInsteadOfCrashing() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)
        try await test.database.writer.write { db in
            try db.execute(sql: "UPDATE host SET protocol = 'telnet'")
        }

        await #expect(throws: UnknownStoredValueError.self) {
            try await repository.hosts()
        }
    }

    // MARK: - Updating

    @Test func updatedHostReadsBackWithItsNewValues() async throws {
        let group = HostGroup(name: "Homelab")
        let tag = Tag(name: "Staging", color: .purple)
        try await repository.create(group)
        try await repository.create(tag)
        var host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)

        host.name = "nas-2"
        host.address = "10.0.0.2"
        host.groupID = group.id
        host.tagIDs = [tag.id]
        host.isFavorite = true
        try await repository.update(host)

        #expect(try await repository.host(id: host.id) == host)
    }

    @Test func removingAHostsGroupAndTagsSticks() async throws {
        let group = HostGroup(name: "Homelab")
        let tag = Tag(name: "Staging", color: .purple)
        try await repository.create(group)
        try await repository.create(tag)
        var host = Host(name: "nas", address: "nas.lan", username: "admin", groupID: group.id, tagIDs: [tag.id])
        try await repository.create(host)

        host.groupID = nil
        host.tagIDs = []
        try await repository.update(host)

        #expect(try await repository.host(id: host.id) == host)
    }

    @Test func updatingAnUnknownHostThrows() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin")

        await #expect(throws: HostRepositoryError.hostNotFound(host.id)) {
            try await repository.update(host)
        }
    }

    // MARK: - Deleting

    @Test func deletingAHostWritesATombstoneThatFetchesLeaveOut() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin")
        let kept = Host(name: "forge", address: "forge.lan", username: "dev")
        try await repository.create(host)
        try await repository.create(kept)
        let deletion = Date(timeIntervalSinceReferenceDate: 800_000_600)
        test.clock.set(deletion)

        try await repository.deleteHost(id: host.id)

        #expect(try await repository.host(id: host.id) == nil)
        #expect(try await repository.hosts() == [kept])
        let tombstone = try #require(try await test.hostRecord(id: host.id))
        #expect(tombstone.deletedAt == deletion)
        #expect(tombstone.name == "nas")
    }

    @Test func deletingADeletedHostKeepsTheFirstDeletionTime() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)
        let deletion = Date(timeIntervalSinceReferenceDate: 800_000_600)
        test.clock.set(deletion)
        try await repository.deleteHost(id: host.id)
        test.clock.set(deletion.addingTimeInterval(60))

        try await repository.deleteHost(id: host.id)

        #expect(try await test.hostRecord(id: host.id)?.deletedAt == deletion)
    }

    @Test func deletedHostCannotBeUpdated() async throws {
        var host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)
        try await repository.deleteHost(id: host.id)

        host.name = "nas-2"
        await #expect(throws: HostRepositoryError.hostNotFound(host.id)) {
            try await repository.update(host)
        }
    }

    @Test func deletingAnUnknownHostThrows() async throws {
        let id = UUID()

        await #expect(throws: HostRepositoryError.hostNotFound(id)) {
            try await repository.deleteHost(id: id)
        }
    }

    // MARK: - Connections

    /// A connection records when it signed in, for Recents (README section 3). Only that field and
    /// its modification time change: an edit made meanwhile, which the tab never saw, stays.
    @Test func recordingAConnectionChangesOnlyTheLastConnection() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)
        var edited = host
        edited.notes = "Edited while a tab was open."
        try await repository.update(edited)
        let connectedAt = Date(timeIntervalSinceReferenceDate: 800_000_120)
        test.clock.set(connectedAt.addingTimeInterval(1))

        try await repository.recordConnection(toHost: host.id, at: connectedAt)

        edited.lastConnectedAt = connectedAt
        #expect(try await repository.host(id: host.id) == edited)
        let times = try await test.modificationTimes(table: "host", id: host.id)
        #expect(times["lastConnectedAtModifiedAt"] == connectedAt.addingTimeInterval(1))
    }

    /// The host connected to last comes first among the recents.
    @Test func lastConnectedHostComesFirstAmongTheRecents() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        let web = Host(name: "web", address: "web.lan", username: "deploy")
        try await repository.create(nas)
        try await repository.create(web)

        try await repository.recordConnection(toHost: nas.id, at: Date(timeIntervalSinceReferenceDate: 800_000_000))
        try await repository.recordConnection(toHost: web.id, at: Date(timeIntervalSinceReferenceDate: 800_000_060))

        #expect(try await repository.hosts(HostQuery(order: .recents)).map(\.name) == ["web", "nas"])
    }

    /// A host deleted while its tab was open is not brought back by its connection.
    @Test func recordingAConnectionToADeletedHostThrows() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)
        try await repository.deleteHost(id: host.id)

        await #expect(throws: HostRepositoryError.hostNotFound(host.id)) {
            try await repository.recordConnection(toHost: host.id, at: .now)
        }
        #expect(try await test.hostRecord(id: host.id)?.lastConnectedAt == nil)
    }
}
