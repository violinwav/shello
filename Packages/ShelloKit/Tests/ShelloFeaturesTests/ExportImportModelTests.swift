import Foundation
import ShelloModel
import ShelloStorage
import Testing

@testable import ShelloFeatures

/// Export and import in Settings (README section 15).
@Suite(.timeLimit(.minutes(1)))
struct ExportImportModelTests {
    let test: TestDatabase
    let model: ExportImportModel
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
        model = ExportImportModel(repository: test.exports)
    }

    private let homelab = HostGroup(name: "Homelab")
    private let staging = Tag(name: "Staging", color: .purple)

    /// Stores a host in Homelab tagged Staging, and returns it.
    @discardableResult
    private func storeNAS() async throws -> Host {
        try await repository.create(homelab)
        try await repository.create(staging)
        let nas = Host(name: "nas", address: "nas.lan", username: "admin", groupID: homelab.id, tagIDs: [staging.id])
        try await repository.create(nas)
        return nas
    }

    /// Writes `data` to a file of its own, as the file importer would hand it over.
    private func file(_ data: Data) throws -> URL {
        let url = test.root.deletingLastPathComponent().appending(path: "Import-\(UUID().uuidString).json")
        try data.write(to: url)
        return url
    }

    // MARK: - Export

    @Test func exportPreparesTheFileAndOpensTheExporter() async throws {
        let nas = try await storeNAS()

        await model.export()

        #expect(model.isExporting)
        let document = try #require(model.exportDocument)
        let file = try ExportFile(data: document.data)
        #expect(file.hosts == [nas])
        #expect(file.groups == [homelab])
        #expect(file.tags == [staging])
    }

    @Test func savedExportSaysWhatItHolds() async throws {
        try await storeNAS()
        await model.export()

        model.exportFinished(.success(test.root.appending(path: "Shello Export.json")))

        #expect(model.status == "Exported 1 host, 1 group and 1 tag.")
        #expect(model.exportDocument == nil)
        #expect(model.alert == nil)
    }

    @Test func exportThatCouldNotBeSavedSaysWhy() async throws {
        try await storeNAS()
        await model.export()

        model.exportFinished(.failure(CocoaError(.fileWriteOutOfSpace)))

        #expect(model.status == nil)
        #expect(model.alert?.title == "Couldn’t Save the Export")
        #expect(model.exportDocument == nil)
    }

    @Test func cancelledExportSaysNothing() async throws {
        try await storeNAS()
        await model.export()

        model.exportCancelled()

        #expect(model.status == nil)
        #expect(model.alert == nil)
        #expect(model.exportDocument == nil)
    }

    /// The name is fixed when the export is made: one that changed while the exporter shows would
    /// reset it.
    @Test func exportIsNamedAfterTheTimeItIsMade() async throws {
        let time = try #require(
            Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 5, second: 9)))
        let model = ExportImportModel(repository: test.exports, now: { time })

        await model.export()

        #expect(model.exportFilename == "Shello Export 2026-10-21 23.05.09")
    }

    /// What the last export or import did gives way to what the next one does.
    @Test func newExportOrImportClearsTheLastStatus() async throws {
        try await storeNAS()
        await model.export()
        model.exportFinished(.success(test.root.appending(path: "Shello Export.json")))
        #expect(model.status != nil)

        await model.fileChosen(.success(try file(Data("{".utf8))))

        #expect(model.status == nil)
        #expect(model.activity == nil)
        #expect(model.alert?.title == "Can’t Import the File")
    }

    // MARK: - Import

    @Test func chosenFileIsSummarizedForTheUserToConfirmBeforeAnythingIsImported() async throws {
        let nas = try await storeNAS()
        let forge = Host(name: "forge", address: "forge.lan", username: "dev", groupID: homelab.id)
        try await repository.create(forge)
        let data = try await test.exports.export().encoded()
        try await repository.deleteHost(id: forge.id)
        var renamed = nas
        renamed.name = "nas-2"
        try await repository.update(renamed)

        await model.fileChosen(.success(try file(data)))

        guard case .confirmImport(let pending) = model.alert else {
            Issue.record("\(String(describing: model.alert)) does not ask to confirm the import")
            return
        }
        #expect(pending.title == "Import 2 hosts, 1 group and 1 tag?")
        #expect(
            pending.message
                == "Hosts, groups and tags already in Shello are replaced by their version in the file. "
                + "This replaces 1 host, 1 group and 1 tag. Nothing else changes.")
        #expect(try await repository.hosts() == [renamed])
    }

    @Test func confirmingTheImportStoresTheRecordsAndSaysSo() async throws {
        let other = try TestDatabase()
        let nas = try await storeNAS()
        let data = try await test.exports.export().encoded()
        let model = ExportImportModel(repository: other.exports)
        await model.fileChosen(.success(try file(data)))
        guard case .confirmImport(let pending) = model.alert else {
            Issue.record("\(String(describing: model.alert)) does not ask to confirm the import")
            return
        }
        #expect(pending.message.hasSuffix("None of these are in Shello yet. Nothing else changes."))

        await model.confirmImport(pending)

        #expect(model.status == "Imported 1 host, 1 group and 1 tag.")
        #expect(try await other.repository.hosts() == [nas])
        #expect(try await other.repository.groups() == [homelab])
        #expect(try await other.repository.tags() == [staging])
    }

    @Test func fileFromANewerShelloIsRefusedWithTheReason() async throws {
        let nas = try await storeNAS()

        await model.fileChosen(.success(try file(Data(#"{"format":"ch.shello.export","schemaVersion":2}"#.utf8))))

        #expect(model.alert?.title == "Can’t Import the File")
        #expect(
            model.alert?.message
                == "The file comes from a newer version of Shello. Update Shello, then import the file again.")
        #expect(try await repository.hosts() == [nas])
    }

    @Test func truncatedFileIsRefusedWithTheReason() async throws {
        try await storeNAS()
        let data = try await test.exports.export().encoded()

        await model.fileChosen(.success(try file(data.prefix(data.count / 2))))

        #expect(model.alert?.title == "Can’t Import the File")
        #expect(model.alert?.message == "The file isn’t a Shello export, or it’s damaged or incomplete.")
    }

    @Test func fileLargerThanAnyExportIsRefusedUnread() async throws {
        let url = try file(Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ExportFile.maximumByteCount) + 1)
        try handle.close()

        await model.fileChosen(.success(url))

        #expect(model.alert?.message == "The file is too large to be a Shello export.")
    }

    @Test func fileWithoutHostsGroupsOrTagsSaysThereIsNothingToImport() async throws {
        let data = try await test.exports.export().encoded()

        await model.fileChosen(.success(try file(data)))

        #expect(model.alert == .nothingToImport)
        #expect(model.alert?.title == "Nothing to Import")
    }

    @Test func fileTheImporterCouldNotOpenSaysWhy() async throws {
        await model.fileChosen(.failure(CocoaError(.fileReadNoPermission)))

        #expect(model.alert?.title == "Can’t Open the File")
    }

    // MARK: - Counts

    @Test(arguments: [
        (RecordCounts(hosts: 12, groups: 3, tags: 5), "12 hosts, 3 groups and 5 tags"),
        (RecordCounts(hosts: 1, groups: 1, tags: 1), "1 host, 1 group and 1 tag"),
        (RecordCounts(hosts: 2, groups: 0, tags: 1), "2 hosts and 1 tag"),
        (RecordCounts(hosts: 0, groups: 4, tags: 0), "4 groups"),
        (RecordCounts(hosts: 0, groups: 0, tags: 0), "no hosts, groups or tags"),
    ])
    func countsNameEachKindOfRecord(_ counts: RecordCounts, _ text: String) {
        #expect(counts.listed == text)
    }
}
