import Foundation
import GRDB
import ShelloModel

/// Shello's own trust store: the host key the user trusted for each server (README section 3, STACK
/// section 7.2). Trust belongs to the server, its address and port, so it covers every host that
/// points at the server. Shello never reads or writes OpenSSH's `known_hosts`.
///
/// Trusting adds a key for a server that has none. It never replaces a trusted key: a changed host
/// key blocks the connection, and replacing the key takes an explicit action of its own,
/// `replace(_:with:of:)`.
public struct HostKeyRepository: Sendable {
    private let database: AppDatabase
    private let now: @Sendable () -> Date

    public init(_ database: AppDatabase) {
        self.init(database, now: { Date() })
    }

    init(_ database: AppDatabase, now: @escaping @Sendable () -> Date) {
        self.database = database
        self.now = now
    }

    /// The host key trusted for `server`, or nil if the user has not trusted one.
    public func trustedKey(of server: Server) async throws -> TrustedHostKey? {
        try await database.writer.read { db in
            try HostKeyRecord.fetchOne(db, key: Self.primaryKey(of: server))?.trustedHostKey
        }
    }

    /// Trusts `key` for `server`, as the user asked on the first connection to it. Trusting the key
    /// that is trusted already changes nothing.
    /// - Throws: `HostKeyRepositoryError.otherKeyTrusted` if another key is trusted for the server.
    public func trust(_ key: HostKey, of server: Server) async throws {
        try await database.writer.write { db in
            if let trusted = try HostKeyRecord.fetchOne(db, key: Self.primaryKey(of: server))?.trustedHostKey {
                guard trusted.key == key else {
                    throw HostKeyRepositoryError.otherKeyTrusted(server, trusted: trusted)
                }
                return
            }
            try HostKeyRecord(key, of: server, trustedAt: now()).insert(db)
        }
    }

    /// Replaces the host key trusted for `server`, `trusted`, with `key`: the explicit action of README
    /// section 3, which the caller confirms with the user, and LocalAuthentication, first. The trust
    /// is as new as the replacement.
    /// - Throws: `HostKeyRepositoryError.otherKeyTrusted` if the key trusted for the server is not
    ///   `trusted` any more, `.noKeyTrusted` if none is: the user agreed to replace that key only.
    public func replace(_ trusted: HostKey, with key: HostKey, of server: Server) async throws {
        try await database.writer.write { db in
            guard let record = try HostKeyRecord.fetchOne(db, key: Self.primaryKey(of: server)) else {
                throw HostKeyRepositoryError.noKeyTrusted(server)
            }
            let current = record.trustedHostKey
            guard current.key == trusted else {
                throw HostKeyRepositoryError.otherKeyTrusted(server, trusted: current)
            }
            try HostKeyRecord(key, of: server, trustedAt: now()).update(db)
        }
    }

    private static func primaryKey(of server: Server) -> [String: any DatabaseValueConvertible] {
        [HostKeyRecord.Columns.address.name: server.address, HostKeyRecord.Columns.port.name: server.port]
    }
}

public enum HostKeyRepositoryError: Error, Equatable, CustomStringConvertible {
    /// A different host key is trusted for the server, and trusting replaces no key.
    case otherKeyTrusted(Server, trusted: TrustedHostKey)
    /// No host key is trusted for the server, so there is none to replace.
    case noKeyTrusted(Server)

    public var description: String {
        switch self {
        case .otherKeyTrusted(let server, let trusted):
            "Another host key is trusted for \(server): \(trusted.key.fingerprint)."
        case .noKeyTrusted(let server):
            "No host key is trusted for \(server)."
        }
    }
}
