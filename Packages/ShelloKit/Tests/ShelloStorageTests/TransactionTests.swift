import Foundation
import GRDB
import ShelloModel
import Testing

@testable import ShelloStorage

/// Every write is one transaction (README section 16): a write that stops part-way leaves nothing
/// of itself behind.
struct TransactionTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
    }

    /// Makes every later write of a host's tags fail. A host's own row is written before its tags,
    /// so this interrupts a host write half-way.
    private func interruptWritingTags() async throws {
        try await test.database.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TEMP TRIGGER interruptWritingTags BEFORE INSERT ON hostTag
                    BEGIN SELECT RAISE(ABORT, 'interrupted'); END
                    """)
        }
    }

    @Test func interruptedCreateLeavesNoPartialHostBehind() async throws {
        let tag = Tag(name: "Production", color: .red)
        try await repository.create(tag)
        let host = Host(name: "prod-api-01", address: "10.0.4.21", username: "deploy", tagIDs: [tag.id])
        try await interruptWritingTags()

        await #expect(throws: DatabaseError.self) {
            try await repository.create(host)
        }

        #expect(try await repository.hosts().isEmpty)
        #expect(try await test.hostRecord(id: host.id) == nil)
    }

    @Test func interruptedUpdateKeepsThePreviousHost() async throws {
        let production = Tag(name: "Production", color: .red)
        let staging = Tag(name: "Staging", color: .purple)
        try await repository.create(production)
        try await repository.create(staging)
        let host = Host(name: "prod-api-01", address: "10.0.4.21", username: "deploy", tagIDs: [production.id])
        try await repository.create(host)
        try await interruptWritingTags()

        var changed = host
        changed.name = "prod-api-02"
        changed.tagIDs = [staging.id]
        await #expect(throws: DatabaseError.self) {
            try await repository.update(changed)
        }

        #expect(try await repository.host(id: host.id) == host)
    }

    @Test func hostWithATagThatDoesNotExistIsNotStored() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin", tagIDs: [UUID()])

        await #expect(throws: DatabaseError.self) {
            try await repository.create(host)
        }

        #expect(try await test.hostRecord(id: host.id) == nil)
    }

    @Test func hostInAGroupThatDoesNotExistIsNotStored() async throws {
        let host = Host(name: "nas", address: "nas.lan", username: "admin", groupID: UUID())

        await #expect(throws: DatabaseError.self) {
            try await repository.create(host)
        }

        #expect(try await test.hostRecord(id: host.id) == nil)
    }
}
