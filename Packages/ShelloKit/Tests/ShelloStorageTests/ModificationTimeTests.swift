import Foundation
import GRDB
import ShelloModel
import Testing

@testable import ShelloStorage

/// Sync merges per field, the later change winning (README section 15), so every synced field keeps
/// its own modification time. A write must move only the times of the fields it changed.
struct ModificationTimeTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }
    let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let changed = Date(timeIntervalSinceReferenceDate: 800_000_060)

    init() throws {
        test = try TestDatabase()
        test.clock.set(created)
    }

    @Test(arguments: HostFieldChange.all)
    func changingOneHostFieldMovesOnlyItsModificationTime(_ field: HostFieldChange) async throws {
        let group = HostGroup(name: "Homelab")
        let tag = Tag(name: "Staging", color: .purple)
        try await repository.create(group)
        try await repository.create(tag)
        var host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)

        test.clock.set(changed)
        field.change(&host, group, tag)
        try await repository.update(host)

        let times = try await test.modificationTimes(table: "host", id: host.id)
        #expect(times[field.timeColumn] == changed)
        #expect(times.filter { $0.key != field.timeColumn }.values.allSatisfy { $0 == created })
    }

    @Test func everySyncedHostFieldIsCovered() async throws {
        let columns = try await test.database.writer.read { db in
            try db.columns(in: "host").map(\.name).filter { $0.hasSuffix("ModifiedAt") }
        }

        // Deleting is covered by deletingStampsTheTombstone.
        #expect(Set(columns) == Set(HostFieldChange.all.map(\.timeColumn) + ["deletedAtModifiedAt"]))
    }

    @Test func savingAnUnchangedHostMovesNoModificationTime() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)

        test.clock.set(changed)
        try await repository.update(host)

        let times = try await test.modificationTimes(table: "host", id: host.id)
        #expect(!times.isEmpty)
        #expect(times.values.allSatisfy { $0 == created })
    }

    @Test func deletingStampsTheTombstone() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(host)

        test.clock.set(changed)
        try await repository.deleteHost(id: host.id)

        let times = try await test.modificationTimes(table: "host", id: host.id)
        #expect(times["deletedAtModifiedAt"] == changed)
        #expect(times.filter { $0.key != "deletedAtModifiedAt" }.values.allSatisfy { $0 == created })
    }
}

/// One synced host field, and a change to it.
struct HostFieldChange: Sendable, CustomTestStringConvertible {
    let field: String
    let change: @Sendable (inout Host, HostGroup, Tag) -> Void

    var timeColumn: String { field + "ModifiedAt" }
    var testDescription: String { field }

    static let all: [HostFieldChange] = [
        HostFieldChange(field: "name") { host, _, _ in host.name = "nas-2" },
        HostFieldChange(field: "address") { host, _, _ in host.address = "10.0.0.2" },
        HostFieldChange(field: "port") { host, _, _ in host.port = 2222 },
        HostFieldChange(field: "protocol") { host, _, _ in host.protocol = .mosh },
        HostFieldChange(field: "username") { host, _, _ in host.username = "root" },
        HostFieldChange(field: "authMethod") { host, _, _ in host.authMethod = .password },
        HostFieldChange(field: "sshKeyID") { host, _, _ in host.sshKeyID = UUID() },
        HostFieldChange(field: "groupID") { host, group, _ in host.groupID = group.id },
        HostFieldChange(field: "tags") { host, _, tag in host.tagIDs = [tag.id] },
        HostFieldChange(field: "notes") { host, _, _ in host.notes = "Backups run at 03:00." },
        HostFieldChange(field: "startupCommand") { host, _, _ in host.startupCommand = "htop" },
        HostFieldChange(field: "tmuxAutoAttach") { host, _, _ in host.tmuxAutoAttach = true },
        HostFieldChange(field: "tmuxSessionName") { host, _, _ in host.tmuxSessionName = "work" },
        // The list is one field: its order, too, is the later change's.
        HostFieldChange(field: "jumpHostIDs") { host, _, _ in host.jumpHostIDs = [UUID(), UUID()] },
        HostFieldChange(field: "terminalType") { host, _, _ in host.terminalType = "xterm" },
        HostFieldChange(field: "keepaliveInterval") { host, _, _ in host.keepaliveInterval = .seconds(60) },
        HostFieldChange(field: "connectTimeout") { host, _, _ in host.connectTimeout = .seconds(5) },
        HostFieldChange(field: "isFavorite") { host, _, _ in host.isFavorite = true },
        HostFieldChange(field: "lastConnectedAt") { host, _, _ in
            host.lastConnectedAt = Date(timeIntervalSinceReferenceDate: 800_000_030)
        },
    ]
}
