import Foundation
import GRDB

/// The database schema, as an ordered list of migrations.
///
/// A schema change is a new migration, registered after the others. A migration that shipped never
/// changes, because databases on devices have already run it: each one has a fixture database, and
/// MigrationTests checks that the migration still builds exactly that schema.
///
/// The schema is ready for sync (docs/spec/STACK.md section 7.10):
/// - Identifiers are UUIDs, stored as 16-byte blobs.
/// - Every synced field has a modification time next to it, `<field>ModifiedAt`, so that sync can
///   merge per field. A host's tags are one field, `tagsModifiedAt`, and so are its jump hosts.
/// - Deleting writes a tombstone: `deletedAt` is set and the row stays, so that the deletion can sync
///   and be undone. `deletedAt` has its own modification time, which also covers an undo.
/// - Foreign keys are deferred to the end of the transaction, so that a write can store related rows
///   in any order.
/// - Times are seconds since 2001-01-01 (`Date.timeIntervalSinceReferenceDate`), durations whole
///   milliseconds. Enum values are stored as fixed strings (`StoredEnum`).
enum Schema {
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: v1)
        migrator.registerMigration("v2", migrate: v2)
        migrator.registerMigration("v3", migrate: v3)
        migrator.registerMigration("v4", migrate: v4)
        return migrator
    }()

    /// Hosts, groups and tags (README section 3).
    private static func v1(_ db: Database) throws {
        try db.create(table: "hostGroup", options: .strict) { t in
            t.primaryKey("id", .blob)
            t.column("name", .text).notNull()
            t.column("nameModifiedAt", .real).notNull()
            t.column("deletedAt", .real)
            t.column("deletedAtModifiedAt", .real).notNull()
        }
        try db.create(table: "tag", options: .strict) { t in
            t.primaryKey("id", .blob)
            t.column("name", .text).notNull()
            t.column("nameModifiedAt", .real).notNull()
            t.column("color", .text).notNull()
            t.column("colorModifiedAt", .real).notNull()
            t.column("deletedAt", .real)
            t.column("deletedAtModifiedAt", .real).notNull()
        }
        try db.create(table: "host", options: .strict) { t in
            t.primaryKey("id", .blob)
            t.column("name", .text).notNull()
            t.column("nameModifiedAt", .real).notNull()
            t.column("address", .text).notNull()
            t.column("addressModifiedAt", .real).notNull()
            t.column("port", .integer).notNull()
            t.column("portModifiedAt", .real).notNull()
            t.column("protocol", .text).notNull()
            t.column("protocolModifiedAt", .real).notNull()
            t.column("username", .text).notNull()
            t.column("usernameModifiedAt", .real).notNull()
            t.column("authMethod", .text).notNull()
            t.column("authMethodModifiedAt", .real).notNull()
            // No foreign key: the SSH key may exist on another device only (README section 15).
            t.column("sshKeyID", .blob)
            t.column("sshKeyIDModifiedAt", .real).notNull()
            t.column("groupID", .blob).references("hostGroup", onDelete: .setNull, deferred: true).indexed()
            t.column("groupIDModifiedAt", .real).notNull()
            t.column("tagsModifiedAt", .real).notNull()
            t.column("notes", .text).notNull()
            t.column("notesModifiedAt", .real).notNull()
            t.column("startupCommand", .text).notNull()
            t.column("startupCommandModifiedAt", .real).notNull()
            t.column("terminalType", .text).notNull()
            t.column("terminalTypeModifiedAt", .real).notNull()
            t.column("keepaliveInterval", .integer).notNull()
            t.column("keepaliveIntervalModifiedAt", .real).notNull()
            t.column("connectTimeout", .integer).notNull()
            t.column("connectTimeoutModifiedAt", .real).notNull()
            t.column("isFavorite", .integer).notNull()
            t.column("isFavoriteModifiedAt", .real).notNull()
            t.column("lastConnectedAt", .real)
            t.column("lastConnectedAtModifiedAt", .real).notNull()
            t.column("deletedAt", .real)
            t.column("deletedAtModifiedAt", .real).notNull()
        }
        try db.create(table: "hostTag", options: .strict) { t in
            t.primaryKey {
                t.column("hostID", .blob).references("host", onDelete: .cascade, deferred: true)
                t.column("tagID", .blob).references("tag", onDelete: .cascade, deferred: true).indexed()
            }
        }
    }

    /// Trusted host keys (README section 3): the host key the user accepted for a server, keyed by
    /// the server's address, in lowercase, and port, so that it covers every host that points at the
    /// server. The key is stored in SSH's wire format with its algorithm and fingerprint. A trusted
    /// key changes as a whole, so `trustedAt` is the modification time of the row.
    private static func v2(_ db: Database) throws {
        try db.create(table: "hostKey", options: .strict) { t in
            t.primaryKey {
                t.column("address", .text).notNull()
                t.column("port", .integer).notNull()
            }
            t.column("algorithm", .text).notNull()
            t.column("key", .blob).notNull()
            t.column("fingerprint", .text).notNull()
            t.column("trustedAt", .real).notNull()
        }
    }

    /// tmux auto-attach (README section 8): whether a host attaches its tmux session, and the
    /// session's name. The hosts that exist get the defaults, auto-attach off and the session `main`,
    /// as hosts behaved before. Their modification time is 0, 2001-01-01, older than any change: when
    /// sync merges per field, a choice made on another device wins over a default.
    private static func v3(_ db: Database) throws {
        try db.alter(table: "host") { t in
            t.add(column: "tmuxAutoAttach", .integer).notNull().defaults(to: false)
            t.add(column: "tmuxAutoAttachModifiedAt", .real).notNull().defaults(to: 0)
            t.add(column: "tmuxSessionName", .text).notNull().defaults(to: "main")
            t.add(column: "tmuxSessionNameModifiedAt", .real).notNull().defaults(to: 0)
        }
    }

    /// Jump hosts (README section 3): the hosts a host is reached through, in order. The list is one
    /// field, so that sync's per-field merge takes the whole list of the later change: their
    /// identifiers, 16 bytes each, one after the other. No foreign key: a deleted jump host is a
    /// tombstone that the lists naming it keep, so that undoing the deletion brings it back in each,
    /// and sync may bring a list before the hosts it names. The hosts that exist get none, as they
    /// were, modified at 0, as in v3.
    private static func v4(_ db: Database) throws {
        try db.alter(table: "host") { t in
            t.add(column: "jumpHostIDs", .blob).notNull().defaults(to: Data())
            t.add(column: "jumpHostIDsModifiedAt", .real).notNull().defaults(to: 0)
        }
    }
}
