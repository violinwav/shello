import Foundation
import GRDB
import ShelloModel

/// Exports all non-secret data as one file, and imports such a file (README section 15). An export
/// leaves deleted records out; an import adds the file's records and replaces those with the same
/// identifier, deleted or not, and keeps everything else.
public struct ExportRepository: Sendable {
    private let database: AppDatabase
    private let now: @Sendable () -> Date

    public init(_ database: AppDatabase) {
        self.init(database, now: { Date() })
    }

    init(_ database: AppDatabase, now: @escaping @Sendable () -> Date) {
        self.database = database
        self.now = now
    }

    /// Every host, group and tag, as one consistent read. A host in a deleted group reads as having
    /// no group, and without its deleted tags, as everywhere else.
    public func export() async throws -> ExportFile {
        try await database.writer.read { db in
            ExportFile(
                groups: try HostRepository.fetchGroups(db),
                tags: try HostRepository.fetchTags(db),
                hosts: try HostRepository.fetchHosts(db, HostQuery().request))
        }
    }

    /// What importing `file` would do: how many records it holds, and how many of them replace a
    /// record already in Shello. A deleted record does not count as one: importing brings it back.
    public func importSummary(of file: ExportFile) async throws -> ImportSummary {
        try await database.writer.read { db in
            let liveHostIDs = try Self.liveIDs(HostRecord.self, db)
            let liveGroupIDs = try Self.liveIDs(HostGroupRecord.self, db)
            let liveTagIDs = try Self.liveIDs(TagRecord.self, db)
            return ImportSummary(
                records: file.counts,
                replacing: RecordCounts(
                    hosts: file.hosts.count(where: { liveHostIDs.contains($0.id) }),
                    groups: file.groups.count(where: { liveGroupIDs.contains($0.id) }),
                    tags: file.tags.count(where: { liveTagIDs.contains($0.id) })))
        }
    }

    /// Stores the file's records in one transaction: all of them, or none if a write fails. A
    /// record with the identifier of one in the database replaces it, and brings it back if it was
    /// deleted. As with every write, only the fields that change get a new modification time.
    public func importFile(_ file: ExportFile) async throws {
        try await database.writer.write { db in
            let now = now()
            // Groups and tags first: the hosts are compared with what they read as afterwards.
            for group in file.groups {
                if var record = try HostGroupRecord.fetchOne(db, id: group.id) {
                    try record.updateChanges(db) { record in
                        record.apply(group, at: now)
                        record.undoDeletion(at: now)
                    }
                } else {
                    try HostGroupRecord(group, modifiedAt: now).insert(db)
                }
            }
            for tag in file.tags {
                if var record = try TagRecord.fetchOne(db, id: tag.id) {
                    try record.updateChanges(db) { record in
                        record.apply(tag, at: now)
                        record.undoDeletion(at: now)
                    }
                } else {
                    try TagRecord(tag, modifiedAt: now).insert(db)
                }
            }
            let liveGroupIDs = try Self.liveIDs(HostGroupRecord.self, db)
            let liveTagIDs = try Self.liveIDs(TagRecord.self, db)
            for host in file.hosts {
                guard let record = try HostRecord.fetchOne(db, id: host.id) else {
                    try HostRecord(host, modifiedAt: now).insert(db)
                    try Self.insertTags(of: host, db)
                    continue
                }
                // The host as it reads now, deleted or not: a deleted group or tag no longer counts.
                let storedTagIDs = try HostTagRecord.filter(HostTagRecord.Columns.hostID == host.id)
                    .select(HostTagRecord.Columns.tagID, as: UUID.self).fetchSet(db)
                let current = try record.host(
                    groupID: record.groupID.flatMap { liveGroupIDs.contains($0) ? $0 : nil },
                    tagIDs: storedTagIDs.intersection(liveTagIDs))
                var updated = record
                updated.apply(host, changedFrom: current, at: now)
                updated.undoDeletion(at: now)
                try updated.updateChanges(db, from: record)
                if host.tagIDs != current.tagIDs {
                    try HostTagRecord.filter(HostTagRecord.Columns.hostID == host.id).deleteAll(db)
                    try Self.insertTags(of: host, db)
                }
            }
        }
    }

    /// The identifiers of the rows that are not tombstones.
    private static func liveIDs<Record: StoredRecord & Tombstoned>(_: Record.Type, _ db: Database) throws -> Set<UUID> {
        try Record.filter(Column("deletedAt") == nil).select(Column("id"), as: UUID.self).fetchSet(db)
    }

    private static func insertTags(of host: Host, _ db: Database) throws {
        for tagID in host.tagIDs {
            try HostTagRecord(hostID: host.id, tagID: tagID).insert(db)
        }
    }
}

/// What an import would do, for the user to confirm.
public struct ImportSummary: Hashable, Sendable {
    /// The records in the file.
    public let records: RecordCounts
    /// The records in the file that replace one already in Shello.
    public let replacing: RecordCounts

    public init(records: RecordCounts, replacing: RecordCounts) {
        self.records = records
        self.replacing = replacing
    }
}
