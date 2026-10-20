import Foundation
import GRDB
import ShelloModel
import Testing

@testable import ShelloStorage

/// Each schema version has a fixture in Fixtures/: a database that version wrote, holding a host
/// with every field set, a deleted host and a deleted tag. Opening a fixture must keep all of its
/// data and end on the current schema, and the migrations that built it must still build exactly
/// its schema.
///
/// Before the next schema change, add a fixture of the current version: write such a database with
/// the current code through `HostRepository`, copy it with `VACUUM INTO '…/Fixtures/vN.sqlite'`, add
/// it to `fixtures` together with the migration it ends on, and add a test for its values like
/// `v1FixtureKeepsEveryValue`.
struct MigrationTests {
    /// Each fixture, with the last migration of its schema version.
    static let fixtures = [("v1", "v1")]

    @Test(arguments: fixtures)
    func fixtureMigratesToTheCurrentSchema(_ fixture: String, _: String) async throws {
        let migrated = try TestDatabase(fixture: fixture)
        let fresh = try TestDatabase()

        #expect(try await Self.schema(of: migrated.database.writer) == Self.schema(of: fresh.database.writer))
    }

    /// A migration that shipped must never change: databases on devices already ran it.
    @Test(arguments: fixtures)
    func shippedMigrationsStillBuildTheFixturesSchema(_ fixture: String, _ lastMigration: String) async throws {
        var configuration = Configuration()
        configuration.readonly = true
        let original = try DatabaseQueue(
            path: TestDatabase.fixtureURL(fixture).path(percentEncoded: false), configuration: configuration)
        let rebuilt = try DatabaseQueue()
        try Schema.migrator.migrate(rebuilt, upTo: lastMigration)

        #expect(try await Self.schema(of: rebuilt) == Self.schema(of: original))
    }

    @Test func v1FixtureKeepsEveryValue() async throws {
        let migrated = try TestDatabase(fixture: "v1")
        let repository = migrated.repository

        #expect(try await repository.groups() == [HostGroup(id: Self.id("000000000001"), name: "Homelab")])
        #expect(
            try await repository.tags() == [
                Tag(id: Self.id("000000000011"), name: "Production", color: .red),
                Tag(id: Self.id("000000000012"), name: "Staging", color: .purple),
            ])
        #expect(
            try await repository.hosts() == [
                Host(
                    id: Self.id("000000000102"), name: "forge", address: "forge.lan", port: 22, protocol: .mosh,
                    username: "dev", authMethod: .password, sshKeyID: nil, groupID: nil, tagIDs: [], notes: "",
                    startupCommand: "", terminalType: "xterm", keepaliveInterval: .seconds(30),
                    connectTimeout: .seconds(15), isFavorite: false, lastConnectedAt: nil),
                Host(
                    id: Self.id("000000000101"), name: "prod-api-01", address: "10.0.4.21", port: 2222,
                    protocol: .ssh, username: "deploy", authMethod: .sshKey, sshKeyID: Self.id("000000000201"),
                    groupID: Self.id("000000000001"), tagIDs: [Self.id("000000000011"), Self.id("000000000012")],
                    notes: "Primary API server in Zürich.\nAsk before rebooting.",
                    startupCommand: "tmux new -A -s main", terminalType: "xterm-256color",
                    keepaliveInterval: .seconds(45), connectTimeout: .seconds(20), isFavorite: true,
                    lastConnectedAt: Date(timeIntervalSinceReferenceDate: 800_000_123.456_789)),
            ])

        // What sync needs survives too: the tombstone and the modification times.
        let tombstone = try await migrated.hostRecord(id: Self.id("000000000103"))
        #expect(tombstone?.name == "media-pc")
        #expect(tombstone?.deletedAt == Date(timeIntervalSinceReferenceDate: 800_000_900))
        let times = try await migrated.modificationTimes(table: "host", id: Self.id("000000000101"))
        #expect(times["nameModifiedAt"] == Date(timeIntervalSinceReferenceDate: 800_000_500))
        #expect(times["addressModifiedAt"] == Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    /// Every table, index and trigger, with the SQL that creates it.
    private static func schema(of reader: some DatabaseReader) async throws -> [String] {
        try await reader.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT type || ' ' || name || ': ' || ifnull(sql, '') FROM sqlite_master
                    ORDER BY type, name
                    """)
        }
    }

    private static func id(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }
}
