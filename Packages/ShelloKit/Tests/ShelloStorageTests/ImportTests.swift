import Foundation
import GRDB
import ShelloModel
import Testing

@testable import ShelloStorage

/// Importing an export file (README section 15): its records are added, a record with the
/// identifier of one already in Shello replaces it, and everything else stays.
struct ImportTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }
    var exports: ExportRepository { test.exports }

    init() throws {
        test = try TestDatabase()
    }

    /// A file version 1 wrote keeps importing, with every value, in every later version. Its hosts
    /// do not attach a tmux session, as hosts did not before version 2.
    @Test func version1FixtureImportsEveryValue() async throws {
        let file = try ExportFile(data: Data(contentsOf: ExportSample.fixtureURL(schemaVersion: 1)))

        try await exports.importFile(file)

        #expect(try await repository.groups() == [ExportSample.homelab, ExportSample.work])
        #expect(try await repository.tags() == ExportSample.tags.sorted { $0.name < $1.name })
        #expect(try await Set(repository.hosts()) == Set(ExportSample.version1Hosts))
    }

    /// A file version 2 wrote, with a host that attaches a tmux session, keeps importing too.
    @Test func version2FixtureImportsEveryValue() async throws {
        let file = try ExportFile(data: Data(contentsOf: ExportSample.fixtureURL(schemaVersion: 2)))

        try await exports.importFile(file)

        #expect(try await repository.groups() == [ExportSample.homelab, ExportSample.work])
        #expect(try await repository.tags() == ExportSample.tags.sorted { $0.name < $1.name })
        #expect(try await Set(repository.hosts()) == Set(ExportSample.hosts))
        #expect(try await repository.hosts().contains { $0.tmuxAutoAttach && $0.tmuxSessionName == "dev_work-2" })
    }

    /// A version 1 file says nothing about tmux, so a host it replaces gets the defaults back, as
    /// hosts had them when the file was written.
    @Test func version1FileReplacesAHostWithTheTmuxDefaults() async throws {
        var forge = try #require(ExportSample.hosts.first { $0.name == "forge" })
        forge.groupID = nil
        forge.tagIDs = []
        try await repository.create(forge)
        let file = try ExportFile(data: Data(contentsOf: ExportSample.fixtureURL(schemaVersion: 1)))

        try await exports.importFile(file)

        let imported = try #require(try await repository.host(id: forge.id))
        #expect(!imported.tmuxAutoAttach)
        #expect(imported.tmuxSessionName == "main")
    }

    @Test func importReplacesRecordsWithTheSameIdentifierAndKeepsTheOthers() async throws {
        let homelab = HostGroup(name: "Homelab")
        let production = Tag(name: "Production", color: .red)
        try await repository.create(homelab)
        try await repository.create(production)
        let nas = Host(name: "nas", address: "nas.lan", username: "admin", groupID: homelab.id)
        let forge = Host(name: "forge", address: "forge.lan", username: "dev")
        try await repository.create(nas)
        try await repository.create(forge)
        var renamedGroup = homelab
        renamedGroup.name = "Home"
        var recolored = production
        recolored.color = .orange
        let staging = Tag(name: "Staging", color: .purple)
        var changedNAS = nas
        changedNAS.address = "10.0.0.2"
        changedNAS.port = 2222
        changedNAS.tagIDs = [recolored.id, staging.id]
        let media = Host(name: "media-pc", address: "10.0.0.40", protocol: .vnc, username: "florian")
        let file = ExportFile(groups: [renamedGroup], tags: [recolored, staging], hosts: [changedNAS, media])

        try await exports.importFile(file)

        #expect(try await repository.groups() == [renamedGroup])
        #expect(try await repository.tags() == [recolored, staging])
        #expect(try await repository.hosts() == [forge, media, changedNAS])
    }

    /// Restoring an export brings back what was deleted since: the deletion is undone.
    @Test func importBringsBackDeletedRecordsWithTheSameIdentifier() async throws {
        let homelab = HostGroup(name: "Homelab")
        let production = Tag(name: "Production", color: .red)
        try await repository.create(homelab)
        try await repository.create(production)
        let nas = Host(
            name: "nas", address: "nas.lan", username: "admin", groupID: homelab.id, tagIDs: [production.id])
        try await repository.create(nas)
        let file = try await exports.export()
        try await repository.deleteHost(id: nas.id)
        try await repository.deleteGroup(id: homelab.id)
        try await repository.deleteTag(id: production.id)

        try await exports.importFile(file)

        #expect(try await repository.groups() == [homelab])
        #expect(try await repository.tags() == [production])
        #expect(try await repository.hosts() == [nas])
    }

    /// A host keeps its membership of a deleted group or tag in storage, so that undoing the
    /// deletion brings it back (`HostRepository`). An import that leaves it out of the group, or
    /// without the tag, takes it out for good once the group or tag is back.
    @Test func importedHostLeavesARestoredGroupAndTagItIsNotIn() async throws {
        let homelab = HostGroup(name: "Homelab")
        let production = Tag(name: "Production", color: .red)
        try await repository.create(homelab)
        try await repository.create(production)
        let nas = Host(
            name: "nas", address: "nas.lan", username: "admin", groupID: homelab.id, tagIDs: [production.id])
        try await repository.create(nas)
        try await repository.deleteGroup(id: homelab.id)
        try await repository.deleteTag(id: production.id)
        var ungrouped = nas
        ungrouped.groupID = nil
        ungrouped.tagIDs = []

        try await exports.importFile(ExportFile(groups: [homelab], tags: [production], hosts: [ungrouped]))

        #expect(try await repository.host(id: nas.id) == ungrouped)
    }

    /// Sync merges per field (README section 15), so an import, like any write, moves only the
    /// modification times of the fields it changes.
    @Test func importMovesOnlyTheModificationTimesOfChangedFields() async throws {
        let created = test.clock.now
        let homelab = HostGroup(name: "Homelab")
        try await repository.create(homelab)
        var nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        let imported = created.addingTimeInterval(60)
        test.clock.set(imported)
        nas.address = "10.0.0.2"

        try await exports.importFile(ExportFile(groups: [homelab], tags: [], hosts: [nas]))

        let hostTimes = try await test.modificationTimes(table: "host", id: nas.id)
        #expect(hostTimes["addressModifiedAt"] == imported)
        #expect(hostTimes.filter { $0.key != "addressModifiedAt" }.values.allSatisfy { $0 == created })
        let groupTimes = try await test.modificationTimes(table: "hostGroup", id: homelab.id)
        #expect(groupTimes.values.allSatisfy { $0 == created })
    }

    @Test func importingTheSameFileAgainChangesNothing() async throws {
        try await ExportSample.store(in: repository)
        let file = try await exports.export()
        let before = try await test.snapshot()
        test.clock.set(test.clock.now.addingTimeInterval(60))

        try await exports.importFile(file)

        #expect(try await test.snapshot() == before)
    }

    /// The import is one transaction: a write that fails half-way leaves nothing of the file behind.
    @Test func interruptedImportLeavesTheDatabaseUnchanged() async throws {
        let homelab = HostGroup(name: "Homelab")
        try await repository.create(homelab)
        try await repository.create(Host(name: "nas", address: "nas.lan", username: "admin", groupID: homelab.id))
        let file = try ExportFile(data: ExportSample.exportData())
        let before = try await test.snapshot()
        // A host's tags are written after the groups, the tags and the host's own row, so this
        // stops the import half-way.
        try await test.database.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER interruptWritingTags BEFORE INSERT ON hostTag
                    BEGIN SELECT RAISE(ABORT, 'interrupted'); END
                    """)
        }

        await #expect(throws: DatabaseError.self) {
            try await exports.importFile(file)
        }

        #expect(try await test.snapshot() == before)
    }

    @Test func summaryCountsTheRecordsAndThoseThatReplaceOneInShello() async throws {
        let file = try ExportFile(data: ExportSample.exportData())
        try await repository.create(ExportSample.work)
        try await repository.create(ExportSample.tags[2])
        try await repository.create(ExportSample.tags[3])
        try await repository.create(ExportSample.hosts[2])
        // A deleted record is not in Shello: importing brings it back.
        try await repository.create(ExportSample.homelab)
        try await repository.deleteGroup(id: ExportSample.homelab.id)

        let summary = try await exports.importSummary(of: file)

        #expect(summary.records == RecordCounts(hosts: 3, groups: 2, tags: 7))
        #expect(summary.replacing == RecordCounts(hosts: 1, groups: 1, tags: 2))
    }
}
