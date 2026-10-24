import Foundation
import ShelloModel
import Testing

@testable import ShelloStorage

struct GroupAndTagTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
    }

    // MARK: - Groups

    @Test func renamedGroupReadsBackWithItsNewName() async throws {
        var group = HostGroup(name: "Homelab")
        try await repository.create(group)

        group.name = "Home"
        try await repository.update(group)

        #expect(try await repository.groups() == [group])
    }

    @Test func deletedGroupDisappearsAndItsHostsReadAsUngrouped() async throws {
        let group = HostGroup(name: "Homelab")
        let kept = HostGroup(name: "Work")
        try await repository.create(group)
        try await repository.create(kept)
        let host = Host(name: "nas", address: "nas.lan", username: "admin", groupID: group.id)
        try await repository.create(host)

        try await repository.deleteGroup(id: group.id)

        #expect(try await repository.groups() == [kept])
        #expect(try await repository.host(id: host.id)?.groupID == nil)
    }

    /// The membership stays in the row, so that undoing the group's deletion brings it back.
    @Test func savingAHostOfADeletedGroupKeepsItsStoredMembership() async throws {
        let group = HostGroup(name: "Homelab")
        try await repository.create(group)
        try await repository.create(Host(name: "nas", address: "nas.lan", username: "admin", groupID: group.id))
        try await repository.deleteGroup(id: group.id)
        var host = try #require(try await repository.hosts().first)

        host.name = "nas-2"
        try await repository.update(host)

        #expect(try await test.hostRecord(id: host.id)?.groupID == group.id)
    }

    @Test func updatingAnUnknownGroupThrows() async throws {
        let group = HostGroup(name: "Homelab")

        await #expect(throws: HostRepositoryError.groupNotFound(group.id)) {
            try await repository.update(group)
        }
    }

    @Test func deletedGroupCannotBeUpdated() async throws {
        var group = HostGroup(name: "Homelab")
        try await repository.create(group)
        try await repository.deleteGroup(id: group.id)

        group.name = "Home"
        await #expect(throws: HostRepositoryError.groupNotFound(group.id)) {
            try await repository.update(group)
        }
    }

    @Test func deletingAnUnknownGroupThrows() async throws {
        let id = UUID()

        await #expect(throws: HostRepositoryError.groupNotFound(id)) {
            try await repository.deleteGroup(id: id)
        }
    }

    // MARK: - Tags

    @Test func renamedAndRecoloredTagReadsBackWithItsNewValues() async throws {
        var tag = Tag(name: "Prod", color: .orange)
        try await repository.create(tag)

        tag.name = "Production"
        tag.color = .red
        try await repository.update(tag)

        #expect(try await repository.tags() == [tag])
    }

    @Test func deletedTagDisappearsFromTagsHostsAndSearch() async throws {
        let tag = Tag(name: "Homelab", color: .blue)
        let kept = Tag(name: "Production", color: .red)
        try await repository.create(tag)
        try await repository.create(kept)
        let host = Host(name: "nas", address: "nas.lan", username: "admin", tagIDs: [tag.id, kept.id])
        try await repository.create(host)

        try await repository.deleteTag(id: tag.id)

        #expect(try await repository.tags() == [kept])
        #expect(try await repository.host(id: host.id)?.tagIDs == [kept.id])
        #expect(try await repository.hosts(HostQuery(search: "homelab")).isEmpty)
    }

    @Test func updatingAnUnknownTagThrows() async throws {
        let tag = Tag(name: "Homelab", color: .blue)

        await #expect(throws: HostRepositoryError.tagNotFound(tag.id)) {
            try await repository.update(tag)
        }
    }

    @Test func deletingAnUnknownTagThrows() async throws {
        let id = UUID()

        await #expect(throws: HostRepositoryError.tagNotFound(id)) {
            try await repository.deleteTag(id: id)
        }
    }

    // MARK: - Modification times

    @Test func renamingAGroupMovesOnlyItsNameTime() async throws {
        var group = HostGroup(name: "Homelab")
        try await repository.create(group)
        let created = test.clock.now
        let changed = created.addingTimeInterval(60)
        test.clock.set(changed)

        group.name = "Home"
        try await repository.update(group)

        let times = try await test.modificationTimes(table: "hostGroup", id: group.id)
        #expect(times == ["nameModifiedAt": changed, "deletedAtModifiedAt": created])
    }

    @Test func recoloringATagMovesOnlyItsColorTime() async throws {
        var tag = Tag(name: "Production", color: .orange)
        try await repository.create(tag)
        let created = test.clock.now
        let changed = created.addingTimeInterval(60)
        test.clock.set(changed)

        tag.color = .red
        try await repository.update(tag)

        let times = try await test.modificationTimes(table: "tag", id: tag.id)
        #expect(times == ["nameModifiedAt": created, "colorModifiedAt": changed, "deletedAtModifiedAt": created])
    }

    @Test func deletingAGroupOrTagStampsItsTombstone() async throws {
        let group = HostGroup(name: "Homelab")
        let tag = Tag(name: "Production", color: .red)
        try await repository.create(group)
        try await repository.create(tag)
        let deletion = test.clock.now.addingTimeInterval(60)
        test.clock.set(deletion)

        try await repository.deleteGroup(id: group.id)
        try await repository.deleteTag(id: tag.id)

        #expect(try await test.modificationTimes(table: "hostGroup", id: group.id)["deletedAtModifiedAt"] == deletion)
        #expect(try await test.modificationTimes(table: "tag", id: tag.id)["deletedAtModifiedAt"] == deletion)
    }
}
