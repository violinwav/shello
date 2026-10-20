import Foundation
import GRDB
import ShelloModel
import Testing

@testable import ShelloStorage

struct AppDatabaseTests {
    @Test func hostsSurviveReopeningTheDatabase() async throws {
        let test = try TestDatabase()
        let host = Host(name: "nas", address: "nas.lan", username: "admin")
        try await test.repository.create(host)

        let reopened = HostRepository(try AppDatabase(directory: test.directory))

        #expect(try await reopened.hosts() == [host])
    }

    @Test func databaseUsesWriteAheadLogging() async throws {
        let test = try TestDatabase()

        let mode = try await test.database.writer.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }

        #expect(mode == "wal")
    }

    /// The app posts the notifications (`AppDatabase.suspend()`), which is not tested here: posting
    /// one would suspend every database open in the test process.
    @Test func databaseObservesSuspensionNotifications() throws {
        let test = try TestDatabase()

        #expect(test.database.writer.configuration.observesSuspensionNotifications)
    }

    /// The iOS Simulator ignores Data Protection: it reports no class for a directory, and the
    /// default class for every file, whatever was set. So this runs on a device only.
    @Test(.disabled(if: runsInSimulator, "The iOS Simulator ignores Data Protection classes"))
    func databaseDirectoryAndFileHaveCompleteDataProtection() async throws {
        let test = try TestDatabase()
        try await test.repository.create(Host(name: "nas", address: "nas.lan", username: "admin"))
        let file = test.directory.appending(path: AppDatabase.fileName)

        let fileManager = FileManager.default
        let directoryAttributes = try fileManager.attributesOfItem(atPath: test.directory.path(percentEncoded: false))
        let fileAttributes = try fileManager.attributesOfItem(atPath: file.path(percentEncoded: false))

        #expect(directoryAttributes[.protectionKey] as? FileProtectionType == .complete)
        #expect(fileAttributes[.protectionKey] as? FileProtectionType == .complete)
    }

    @Test func databaseFromANewerShelloIsNotOpened() async throws {
        let test = try TestDatabase()
        try await test.database.writer.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('fromTheFuture')")
        }

        #expect(throws: AppDatabaseError.createdByNewerVersion) {
            try AppDatabase(directory: test.directory)
        }
    }

    /// On a device, an app signed without the App Group finds no container. The simulator finds one
    /// for every process, so the test stands in for the device.
    @Test func missingAppGroupContainerFailsClearly() throws {
        let error = #expect(throws: AppDatabaseError.self) {
            try AppDatabase.appGroupDirectory(containerURL: { _ in nil })
        }

        #expect(error == .appGroupUnavailable(identifier: "group.ch.shello"))
        #expect(error?.description.contains("group.ch.shello") == true)
    }

    @Test func databaseHasItsOwnDirectoryInTheShelloAppGroupContainer() throws {
        let container = URL(filePath: "/var/mobile/Containers/Shared/AppGroup/1234", directoryHint: .isDirectory)
        var requestedGroup: String?

        let directory = try AppDatabase.appGroupDirectory(containerURL: { group in
            requestedGroup = group
            return container
        })

        #expect(requestedGroup == "group.ch.shello")
        #expect(
            directory.path(percentEncoded: false)
                == "/var/mobile/Containers/Shared/AppGroup/1234/Library/Application Support/Database/")
    }
}

private let runsInSimulator: Bool = {
    #if targetEnvironment(simulator)
        true
    #else
        false
    #endif
}()
