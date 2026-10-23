import Foundation
import GRDB
import ShelloModel
import Testing

@testable import ShelloStorage

/// Export of all non-secret data as one JSON file (README section 15, docs/spec/EXPORT.md).
struct ExportTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }
    var exports: ExportRepository { test.exports }

    init() throws {
        test = try TestDatabase()
    }

    /// The safety net against data loss: what one database exports, an empty one imports exactly.
    @Test func exportThenImportIntoAnEmptyDatabaseGivesIdenticalData() async throws {
        try await ExportSample.store(in: repository)
        let empty = try TestDatabase()

        let data = try await exports.export().encoded()
        try await empty.exports.importFile(try ExportFile(data: data))

        #expect(try await empty.repository.groups() == repository.groups())
        #expect(try await empty.repository.tags() == repository.tags())
        #expect(try await empty.repository.hosts() == repository.hosts())
        #expect(try await empty.repository.hosts().count == ExportSample.hosts.count)
        // The imported data exports to the same file.
        #expect(try await empty.exports.export().encoded() == data)
    }

    /// Deleted records are tombstones in the database (`Schema`), and they read as absent everywhere,
    /// the export included.
    @Test func exportLeavesDeletedHostsGroupsAndTagsOut() async throws {
        let homelab = HostGroup(name: "Homelab")
        let retired = HostGroup(name: "Retired")
        let production = Tag(name: "Production", color: .red)
        let legacy = Tag(name: "Legacy", color: .gray)
        for group in [homelab, retired] { try await repository.create(group) }
        for tag in [production, legacy] { try await repository.create(tag) }
        let nas = Host(
            name: "nas", address: "nas.lan", username: "admin", groupID: retired.id, tagIDs: [production.id, legacy.id])
        let gone = Host(name: "old-nas", address: "10.0.0.9", username: "admin")
        try await repository.create(nas)
        try await repository.create(gone)
        try await repository.deleteHost(id: gone.id)
        try await repository.deleteGroup(id: retired.id)
        try await repository.deleteTag(id: legacy.id)

        let file = try await exports.export()

        #expect(file.groups == [homelab])
        #expect(file.tags == [production])
        #expect(file.hosts.map(\.name) == ["nas"])
        #expect(file.hosts.first?.groupID == nil)
        #expect(file.hosts.first?.tagIDs == [production.id])
        let json = String(decoding: try file.encoded(), as: UTF8.self)
        for id in [gone.id, retired.id, legacy.id] {
            #expect(!json.contains(id.uuidString))
        }
    }

    /// Passwords, passphrases and SSH keys never reach the export (README section 13). Every key in
    /// the file is on this list of fields that hold no secret, so that a field added later must be
    /// reviewed here, and the SSH key appears only as its identifier.
    @Test func exportedJSONHasNoSecretFields() async throws {
        try await ExportSample.store(in: repository)

        let data = try await exports.export().encoded()

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["format", "schemaVersion", "groups", "tags", "hosts"])
        let groups = try #require(json["groups"] as? [[String: Any]])
        let tags = try #require(json["tags"] as? [[String: Any]])
        let hosts = try #require(json["hosts"] as? [[String: Any]])
        #expect(groups.allSatisfy { Set($0.keys) == ["id", "name"] })
        #expect(tags.allSatisfy { Set($0.keys) == ["id", "name", "color"] })
        let hostKeys: Set<String> = [
            "id", "name", "address", "port", "protocol", "username", "authMethod", "sshKeyID", "groupID", "tagIDs",
            "notes", "startupCommand", "tmuxAutoAttach", "tmuxSessionName", "terminalType",
            "keepaliveIntervalMilliseconds", "connectTimeoutMilliseconds", "isFavorite", "lastConnectedAt",
        ]
        #expect(hosts.allSatisfy { hostKeys.isSuperset(of: $0.keys) })
        // The sample sets every optional field on one host, so each key on the list shows up.
        #expect(Set(hosts.flatMap(\.keys)) == hostKeys)

        let secretWords = ["password", "passphrase", "secret", "private", "credential", "token"]
        for key in Self.keys(in: json) {
            #expect(!secretWords.contains { key.localizedCaseInsensitiveContains($0) }, "\(key)")
        }
        let sshKeyIDs = hosts.compactMap { $0["sshKeyID"] }
        #expect(sshKeyIDs.count == 1)
        #expect(sshKeyIDs.allSatisfy { ($0 as? String).flatMap(UUID.init(uuidString:)) != nil })
    }

    /// A file this version writes must import into every later version, so its format must not
    /// change while the schema version stays 2. Fixtures/export-v2.json is the sample's export as
    /// version 2 writes it, and export-v1.json as version 1 wrote it; `ImportTests` imports both.
    @Test func exportOfTheSampleIsTheVersion2Fixture() async throws {
        try await ExportSample.store(in: repository)

        let data = try await exports.export().encoded()

        #expect(ExportFile.currentSchemaVersion == 2)
        let fixture = try Data(contentsOf: ExportSample.fixtureURL(schemaVersion: 2))
        #expect(try Self.object(data) == Self.object(fixture))
    }

    /// Every key of every object in `value`.
    private static func keys(in value: Any) -> [String] {
        switch value {
        case let object as [String: Any]: object.keys + object.values.flatMap(keys(in:))
        case let array as [Any]: array.flatMap(keys(in:))
        default: []
        }
    }

    /// The JSON's value, compared regardless of spacing and key order.
    private static func object(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}

/// Data with every kind of value an export holds: each protocol, sign-in method and tag colour,
/// optional values set and not set, text beyond ASCII, and times and durations that need every digit.
enum ExportSample {
    static let homelab = HostGroup(id: id("000000000001"), name: "Homelab")
    static let work = HostGroup(id: id("000000000002"), name: "Work")
    static let tags = Tag.Color.allCases.enumerated().map { index, color in
        Tag(id: id("0000000000\(11 + index)"), name: "Tag \(color)", color: color)
    }

    static let hosts = [
        Host(
            id: id("000000000101"), name: "prod-api-01", address: "10.0.4.21", port: 2222, protocol: .ssh,
            username: "deploy", authMethod: .sshKey, sshKeyID: id("000000000201"), groupID: work.id,
            tagIDs: [tags[0].id, tags[4].id], notes: "Primary API server in Zürich.\nAsk before rebooting.",
            startupCommand: "tmux new -A -s main", terminalType: "xterm-256color", keepaliveInterval: .seconds(45),
            connectTimeout: .milliseconds(7_500), isFavorite: true,
            lastConnectedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)),
        Host(
            id: id("000000000102"), name: "forge", address: "2001:db8::21", protocol: .mosh, username: "dev",
            authMethod: .keyboardInteractive, groupID: homelab.id, tagIDs: [tags[6].id], tmuxAutoAttach: true,
            tmuxSessionName: "dev_work-2", terminalType: "xterm",
            lastConnectedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.000_000_1)),
        Host(
            id: id("000000000103"), name: "Media PC 📺", address: "media-pc.local", protocol: .vnc, username: "",
            authMethod: .password),
    ]

    /// The sample's hosts as a version 1 file holds them: without tmux auto-attach, which version 2
    /// added.
    static var version1Hosts: [Host] {
        hosts.map { host in
            var host = host
            host.tmuxAutoAttach = false
            host.tmuxSessionName = Host.defaultTmuxSessionName
            return host
        }
    }

    static func store(in repository: HostRepository) async throws {
        for group in [homelab, work] { try await repository.create(group) }
        for tag in tags { try await repository.create(tag) }
        for host in hosts { try await repository.create(host) }
    }

    /// The sample's export as `schemaVersion` wrote it.
    static func fixtureURL(schemaVersion: Int) throws -> URL {
        try #require(
            Bundle.module.url(forResource: "export-v\(schemaVersion)", withExtension: "json", subdirectory: "Fixtures"))
    }

    /// The sample's export, as the current version writes it.
    static func exportData() throws -> Data {
        try Data(contentsOf: fixtureURL(schemaVersion: ExportFile.currentSchemaVersion))
    }

    static func id(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }
}
