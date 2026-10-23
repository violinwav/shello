// How the database works: docs/spec/STACK.md section 7.10.
import Foundation
import GRDB

/// Shello's local database: hosts, groups and tags, and trusted host keys, with settings to come.
///
/// Open it once, in the composition root, and share it: two instances on the same file would not see
/// each other's changes in their observations. The app opens it with `openInAppGroup()`, tests with
/// `init(directory:)` and a temporary directory.
public struct AppDatabase: Sendable {
    /// The App Group whose container holds the database, so that extensions can open it too.
    public static let appGroupIdentifier = "group.ch.shello"

    /// The Data Protection class of the database's directory, which covers SQLite's `-wal` and
    /// `-shm` files too. The database need not be readable while the device is locked, because
    /// connections only run in the foreground (README section 13). Spike #14 confirms the class
    /// against Shello's writes; its fallback is `.completeUnlessOpen`. The iOS Simulator ignores
    /// Data Protection, so only a device shows the class.
    public static let fileProtection = FileProtectionType.complete

    static let fileName = "shello.sqlite"

    let writer: DatabasePool

    /// Opens the database in `directory`, creating both if needed, and migrates it to the current
    /// schema. The directory belongs to the database: it gets `fileProtection`, which the files
    /// SQLite creates in it inherit.
    /// - Throws: `AppDatabaseError.createdByNewerVersion` if a newer Shello migrated the database.
    public init(directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.protectionKey: Self.fileProtection], ofItemAtPath: directory.path(percentEncoded: false))

        let path = directory.appending(path: Self.fileName, directoryHint: .notDirectory).path(percentEncoded: false)
        writer = try DatabasePool(path: path, configuration: Self.configuration)
        // An older version must not write to a schema it does not know. Checked on the writer, before
        // any reader connection reads the schema: a reader would keep the schema from before the
        // migration, and read the first rows of a table the migration added columns to without them.
        if try writer.writeWithoutTransaction(Schema.migrator.hasBeenSuperseded) {
            throw AppDatabaseError.createdByNewerVersion
        }
        try Schema.migrator.migrate(writer)
    }

    /// Opens the database in its own directory inside the App Group container.
    /// - Throws: `AppDatabaseError.appGroupUnavailable` if the app is not signed with the App Group.
    public static func openInAppGroup() throws -> AppDatabase {
        try AppDatabase(
            directory: appGroupDirectory(
                containerURL: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)))
    }

    /// The database's directory inside the App Group container. `containerURL` finds a group's
    /// container as `FileManager` does: on a device it finds none for an app signed without the
    /// group, while the simulator finds one for every process.
    static func appGroupDirectory(containerURL: (String) -> URL?) throws -> URL {
        guard let container = containerURL(appGroupIdentifier) else {
            throw AppDatabaseError.appGroupUnavailable(identifier: appGroupIdentifier)
        }
        return container.appending(path: "Library/Application Support/Database", directoryHint: .isDirectory)
    }

    /// Call when the app is about to be suspended, for example when its scene enters the
    /// background. iOS terminates a suspended app that holds a lock on a file in an App Group
    /// container (`0xDEAD10CC`), so the database stops taking locks: writes fail until `resume()`.
    public static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// Call when the app returns to the foreground, to undo `suspend()`.
    public static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    private static var configuration: Configuration {
        var configuration = Configuration()
        // Lets `suspend()` and `resume()` reach every connection. GRDB opens a pool in WAL mode.
        configuration.observesSuspensionNotifications = true
        configuration.prepareDatabase { db in
            db.add(function: localizedStandardContains)
        }
        return configuration
    }

    /// `localizedStandardContains(text, search)` in SQL: whether `text` contains `search`, ignoring
    /// case and diacritics the way the system's own search does. SQLite's `LIKE` only ignores the
    /// case of ASCII letters.
    private static let localizedStandardContains = DatabaseFunction(
        "localizedStandardContains", argumentCount: 2
    ) { arguments in
        guard let text = String.fromDatabaseValue(arguments[0]),
            let search = String.fromDatabaseValue(arguments[1])
        else { return nil }
        return text.localizedStandardContains(search)
    }
}

/// Why the database could not be opened.
public enum AppDatabaseError: Error, Equatable, CustomStringConvertible {
    /// The app has no access to its App Group container: it is not signed with the App Groups
    /// entitlement for this group.
    case appGroupUnavailable(identifier: String)
    /// A newer version of Shello migrated the database, so this version must not write to it.
    case createdByNewerVersion

    public var description: String {
        switch self {
        case .appGroupUnavailable(let identifier):
            "The App Group container \(identifier) is unavailable. Check that the app is signed with "
                + "the App Groups entitlement for \(identifier)."
        case .createdByNewerVersion:
            "The database was created by a newer version of Shello."
        }
    }
}
