import Foundation
import GRDB
import ShelloModel

/// Reads and writes hosts, groups and tags. Every write is one transaction, so a write that fails
/// or is interrupted leaves nothing behind (README section 16).
///
/// Deleting writes a tombstone (`Schema`), which reads leave out. A deleted group or tag no longer
/// counts: a host in a deleted group reads as having no group.
public struct HostRepository: Sendable {
    private let database: AppDatabase
    private let now: @Sendable () -> Date

    public init(_ database: AppDatabase) {
        self.init(database, now: { Date() })
    }

    init(_ database: AppDatabase, now: @escaping @Sendable () -> Date) {
        self.database = database
        self.now = now
    }

    // MARK: - Hosts

    /// Stores a new host. Its group and tags must exist.
    public func create(_ host: Host) async throws {
        try await database.writer.write { db in
            try HostRecord(host, modifiedAt: now()).insert(db)
            for tagID in host.tagIDs {
                try HostTagRecord(hostID: host.id, tagID: tagID).insert(db)
            }
        }
    }

    /// Stores a host's new values. Only the fields that changed get a new modification time.
    /// - Throws: `HostRepositoryError.hostNotFound` if there is no such host, or it was deleted.
    public func update(_ host: Host) async throws {
        try await database.writer.write { db in
            guard let record = try Self.liveRecord(HostRecord.self, id: host.id, db),
                let current = try Self.fetchHosts(db, HostRecord.filter(id: host.id)).first
            else {
                throw HostRepositoryError.hostNotFound(host.id)
            }
            var updated = record
            updated.apply(host, changedFrom: current, at: now())
            try updated.updateChanges(db, from: record)
            if host.tagIDs != current.tagIDs {
                try HostTagRecord.filter(HostTagRecord.Columns.hostID == host.id).deleteAll(db)
                for tagID in host.tagIDs {
                    try HostTagRecord(hostID: host.id, tagID: tagID).insert(db)
                }
            }
        }
    }

    /// Deletes a host by writing a tombstone. Deleting a deleted host changes nothing.
    /// - Throws: `HostRepositoryError.hostNotFound` if there is no such host.
    public func deleteHost(id: Host.ID) async throws {
        try await writeTombstone(HostRecord.self, id: id, ifMissing: .hostNotFound(id))
    }

    /// Records that Shello connected to the host `hostID` at `date`, for Recents (README section 3).
    /// Only `lastConnectedAt` changes, on the host as it is stored now, so that the write never
    /// undoes a change made while the connection was being made.
    /// - Throws: `HostRepositoryError.hostNotFound` if there is no such host, or it was deleted.
    public func recordConnection(toHost hostID: Host.ID, at date: Date) async throws {
        try await database.writer.write { db in
            guard let record = try Self.liveRecord(HostRecord.self, id: hostID, db),
                let current = try Self.fetchHosts(db, HostRecord.filter(id: hostID)).first
            else {
                throw HostRepositoryError.hostNotFound(hostID)
            }
            var connected = current
            connected.lastConnectedAt = date
            var updated = record
            updated.apply(connected, changedFrom: current, at: now())
            try updated.updateChanges(db, from: record)
        }
    }

    /// The host with this identifier, or nil if there is none.
    public func host(id: Host.ID) async throws -> Host? {
        try await database.writer.read { db in
            try Self.fetchHosts(db, HostRecord.filter(id: id)).first
        }
    }

    /// The hosts that match `query`, in its order.
    public func hosts(_ query: HostQuery = HostQuery()) async throws -> [Host] {
        try await database.writer.read { db in
            try Self.fetchHosts(db, query.request)
        }
    }

    // MARK: - Groups

    public func create(_ group: HostGroup) async throws {
        try await database.writer.write { db in
            try HostGroupRecord(group, modifiedAt: now()).insert(db)
        }
    }

    /// Stores a group's new name.
    /// - Throws: `HostRepositoryError.groupNotFound` if there is no such group, or it was deleted.
    public func update(_ group: HostGroup) async throws {
        try await database.writer.write { db in
            guard var record = try Self.liveRecord(HostGroupRecord.self, id: group.id, db) else {
                throw HostRepositoryError.groupNotFound(group.id)
            }
            let now = now()
            try record.updateChanges(db) { $0.apply(group, at: now) }
        }
    }

    /// Deletes a group by writing a tombstone. Its hosts keep their group in storage but read as
    /// having none, so that undoing the deletion brings them back.
    /// - Throws: `HostRepositoryError.groupNotFound` if there is no such group.
    public func deleteGroup(id: HostGroup.ID) async throws {
        try await writeTombstone(HostGroupRecord.self, id: id, ifMissing: .groupNotFound(id))
    }

    /// Every group, sorted by name.
    public func groups() async throws -> [HostGroup] {
        try await database.writer.read(Self.fetchGroups)
    }

    // MARK: - Tags

    public func create(_ tag: Tag) async throws {
        try await database.writer.write { db in
            try TagRecord(tag, modifiedAt: now()).insert(db)
        }
    }

    /// Stores a tag's new name and colour.
    /// - Throws: `HostRepositoryError.tagNotFound` if there is no such tag, or it was deleted.
    public func update(_ tag: Tag) async throws {
        try await database.writer.write { db in
            guard var record = try Self.liveRecord(TagRecord.self, id: tag.id, db) else {
                throw HostRepositoryError.tagNotFound(tag.id)
            }
            let now = now()
            try record.updateChanges(db) { $0.apply(tag, at: now) }
        }
    }

    /// Deletes a tag by writing a tombstone. Its hosts keep it in storage but read without it, so
    /// that undoing the deletion brings it back.
    /// - Throws: `HostRepositoryError.tagNotFound` if there is no such tag.
    public func deleteTag(id: Tag.ID) async throws {
        try await writeTombstone(TagRecord.self, id: id, ifMissing: .tagNotFound(id))
    }

    /// Every tag, sorted by name.
    public func tags() async throws -> [Tag] {
        try await database.writer.read(Self.fetchTags)
    }

    // MARK: - Observation

    /// The hosts that match `query`: first as they are, then again after every change to them,
    /// for as long as the sequence is iterated.
    public func observeHosts(_ query: HostQuery = HostQuery()) -> some AsyncSequence<[Host], any Error> {
        ValueObservation
            .tracking { db in try Self.fetchHosts(db, query.request) }
            .removeDuplicates()
            .values(in: database.writer)
    }

    /// The host with this identifier: first as it is, then again after every change to it, its
    /// group or its tags. Nil while there is no such host, and once it is deleted.
    public func observeHost(id: Host.ID) -> some AsyncSequence<Host?, any Error> {
        ValueObservation
            .tracking { db in try Self.fetchHosts(db, HostRecord.filter(id: id)).first }
            .removeDuplicates()
            .values(in: database.writer)
    }

    /// Every group: first as they are, then again after every change to them.
    public func observeGroups() -> some AsyncSequence<[HostGroup], any Error> {
        ValueObservation.tracking(Self.fetchGroups).removeDuplicates().values(in: database.writer)
    }

    /// Every tag: first as they are, then again after every change to them.
    public func observeTags() -> some AsyncSequence<[Tag], any Error> {
        ValueObservation.tracking(Self.fetchTags).removeDuplicates().values(in: database.writer)
    }

    // MARK: - Tombstones

    /// The row with this identifier, unless it is missing or a tombstone.
    private static func liveRecord<Record: StoredRecord & Tombstoned & Identifiable>(
        _: Record.Type, id: UUID, _ db: Database
    ) throws -> Record? where Record.ID == UUID {
        try Record.fetchOne(db, id: id).flatMap { $0.deletedAt == nil ? $0 : nil }
    }

    private func writeTombstone<Record: StoredRecord & Tombstoned & Identifiable>(
        _: Record.Type, id: UUID, ifMissing error: HostRepositoryError
    ) async throws where Record.ID == UUID {
        try await database.writer.write { db in
            guard var record = try Record.fetchOne(db, id: id) else { throw error }
            guard record.deletedAt == nil else { return }
            let now = now()
            try record.updateChanges(db) {
                $0.deletedAt = now
                $0.deletedAtModifiedAt = now
            }
        }
    }

    // MARK: - Fetching

    /// The hosts that `request` selects, without tombstones, and with the groups and tags that
    /// still count.
    static func fetchHosts(_ db: Database, _ request: QueryInterfaceRequest<HostRecord>) throws -> [Host] {
        let records = try request.filter(HostRecord.Columns.deletedAt == nil).fetchAll(db)
        let liveGroups = HostGroupRecord.filter(HostGroupRecord.Columns.deletedAt == nil)
        let liveGroupIDs = try liveGroups.select(HostGroupRecord.Columns.id, as: UUID.self).fetchSet(db)
        let liveTags = try HostTagRecord.fetchAll(
            db,
            sql: """
                SELECT hostTag.* FROM hostTag
                JOIN tag ON tag.id = hostTag.tagID AND tag.deletedAt IS NULL
                """)
        let tagIDsByHost = Dictionary(grouping: liveTags, by: \.hostID).mapValues { Set($0.map(\.tagID)) }
        return try records.map { record in
            try record.host(
                groupID: record.groupID.flatMap { liveGroupIDs.contains($0) ? $0 : nil },
                tagIDs: tagIDsByHost[record.id] ?? [])
        }
    }

    static func fetchGroups(_ db: Database) throws -> [HostGroup] {
        try HostGroupRecord
            .filter(HostGroupRecord.Columns.deletedAt == nil)
            .order(byName(HostGroupRecord.Columns.name))
            .fetchAll(db)
            .map(\.group)
    }

    static func fetchTags(_ db: Database) throws -> [Tag] {
        try TagRecord
            .filter(TagRecord.Columns.deletedAt == nil)
            .order(byName(TagRecord.Columns.name))
            .fetchAll(db)
            .map { try $0.tag() }
    }

    /// Sorts names the way Finder does: case-insensitively, and with numbers in numeric order.
    /// The identifier breaks ties, so the order is always the same.
    private static func byName(_ name: Column) -> [any SQLOrderingTerm] {
        [name.collating(.localizedStandardCompare), Column("id")]
    }
}

/// A write that names a host, group or tag that does not exist, or was deleted.
public enum HostRepositoryError: Error, Equatable {
    case hostNotFound(Host.ID)
    case groupNotFound(HostGroup.ID)
    case tagNotFound(Tag.ID)
}
