import Foundation
import GRDB
import ShelloModel

/// Stores what an import from OpenSSH's files adds (README section 3): new hosts, and host keys to
/// trust, in one transaction, so that a write that fails leaves nothing behind.
///
/// An import never replaces a trusted host key: that takes the explicit action of the changed-key
/// sheet, and Face ID (README section 3, `HostKeyRepository.replace(_:with:of:)`). A key for a server
/// that has another trusted key, even one trusted since the import was planned, is left out, and the
/// result says so.
public struct HostImportRepository: Sendable {
    private let database: AppDatabase
    private let now: @Sendable () -> Date

    public init(_ database: AppDatabase) {
        self.init(database, now: { Date() })
    }

    init(_ database: AppDatabase, now: @escaping @Sendable () -> Date) {
        self.database = database
        self.now = now
    }

    /// What an import is planned against, as one consistent read: the hosts, deleted ones left out,
    /// and the host key trusted for each server.
    public func savedHostsAndTrustedKeys() async throws -> SavedHostsAndKeys {
        try await database.writer.read { db in
            let hosts = try HostRepository.fetchHosts(db, HostQuery().request)
            var keys: [Server: TrustedHostKey] = [:]
            for record in try HostKeyRecord.fetchAll(db) {
                keys[Server(address: record.address, port: record.port)] = record.trustedHostKey
            }
            return SavedHostsAndKeys(hosts: hosts, trustedKeys: keys)
        }
    }

    /// Adds `hosts`, whose groups and tags must exist, and trusts each of `keys` for its server, in one
    /// transaction. A key is trusted only for a server without a trusted key: one that has the same
    /// key already changes nothing, and one that has another keeps it.
    public func importHosts(_ hosts: [Host], trusting keys: [Server: HostKey]) async throws -> HostImportResult {
        try await database.writer.write { db in
            let now = now()
            for host in hosts {
                try HostRecord(host, modifiedAt: now).insert(db)
                for tagID in host.tagIDs {
                    try HostTagRecord(hostID: host.id, tagID: tagID).insert(db)
                }
            }
            var result = HostImportResult()
            for (server, key) in keys {
                let primaryKey: [String: any DatabaseValueConvertible] = [
                    HostKeyRecord.Columns.address.name: server.address, HostKeyRecord.Columns.port.name: server.port,
                ]
                if let trusted = try HostKeyRecord.fetchOne(db, key: primaryKey)?.trustedHostKey {
                    if trusted.key == key {
                        result.alreadyTrusted.insert(server)
                    } else {
                        result.keptOtherKey.insert(server)
                    }
                } else {
                    try HostKeyRecord(key, of: server, trustedAt: now).insert(db)
                    result.trusted.insert(server)
                }
            }
            return result
        }
    }
}

/// The hosts and trusted host keys an import is planned against.
public struct SavedHostsAndKeys: Hashable, Sendable {
    /// The hosts, deleted ones left out, by name.
    public let hosts: [Host]
    /// The host key trusted for each server that has one.
    public let trustedKeys: [Server: TrustedHostKey]

    public init(hosts: [Host], trustedKeys: [Server: TrustedHostKey]) {
        self.hosts = hosts
        self.trustedKeys = trustedKeys
    }
}

/// What an import did with the host keys it was given.
public struct HostImportResult: Hashable, Sendable {
    /// The servers whose key the import trusted.
    public var trusted: Set<Server> = []
    /// The servers that had the import's key trusted already.
    public var alreadyTrusted: Set<Server> = []
    /// The servers that had another key trusted, which the import kept.
    public var keptOtherKey: Set<Server> = []

    public init() {}
}
