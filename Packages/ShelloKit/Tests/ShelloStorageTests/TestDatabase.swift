import Foundation
import GRDB
import ShelloModel
import Synchronization
import Testing

@testable import ShelloStorage

/// Swift Testing declares a `Tag` type too.
typealias Tag = ShelloModel.Tag

/// An app database in its own temporary directory, deleted when the test ends.
final class TestDatabase: Sendable {
    /// Holds the database directory, and anything a test puts next to it.
    let root: URL
    let database: AppDatabase
    let clock: TestClock
    let repository: HostRepository
    let exports: ExportRepository

    /// The directory the database owns.
    var directory: URL { Self.databaseDirectory(in: root) }

    /// A new database, or one that starts as a copy of `Fixtures/<fixture>.sqlite`.
    init(fixture: String? = nil) throws {
        let root = URL.temporaryDirectory.appending(
            path: "ShelloStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let directory = Self.databaseDirectory(in: root)
        if let fixture {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: try Self.fixtureURL(fixture), to: directory.appending(path: AppDatabase.fileName))
        }
        let clock = TestClock()
        self.root = root
        self.clock = clock
        database = try AppDatabase(directory: directory)
        repository = HostRepository(database, now: { clock.now })
        exports = ExportRepository(database, now: { clock.now })
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    static func databaseDirectory(in root: URL) -> URL {
        root.appending(path: "Database", directoryHint: .isDirectory)
    }

    static func fixtureURL(_ fixture: String) throws -> URL {
        try #require(Bundle.module.url(forResource: fixture, withExtension: "sqlite", subdirectory: "Fixtures"))
    }

    /// A host's row, tombstone or not.
    func hostRecord(id: Host.ID) async throws -> HostRecord? {
        try await database.writer.read { db in try HostRecord.fetchOne(db, id: id) }
    }

    /// Every row of every table, tombstones and modification times included: the whole database,
    /// to compare before and after a write.
    func snapshot() async throws -> [String: [[String: DatabaseValue]]] {
        try await database.writer.read { db in
            let tables = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            var snapshot: [String: [[String: DatabaseValue]]] = [:]
            for table in tables {
                snapshot[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { row in
                    Dictionary(row.map { ($0, $1) }, uniquingKeysWith: { first, _ in first })
                }
            }
            return snapshot
        }
    }

    /// The modification times in a row, by column: `nameModifiedAt` and so on.
    func modificationTimes(table: String, id: UUID) async throws -> [String: Date] {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ?", arguments: [id]) else {
                return [:]
            }
            var times: [String: Date] = [:]
            for (column, value) in row where column.hasSuffix("ModifiedAt") {
                times[column] = Double.fromDatabaseValue(value).map(Date.init(timeIntervalSinceReferenceDate:))
            }
            return times
        }
    }
}

/// A clock that moves only when a test moves it.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))

    var now: Date { current.withLock { $0 } }

    func set(_ date: Date) {
        current.withLock { $0 = date }
    }
}
