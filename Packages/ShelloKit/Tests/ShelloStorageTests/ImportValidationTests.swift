import Foundation
import ShelloModel
import Testing

@testable import ShelloStorage

/// An import is checked completely before it touches the database (STACK section 7.10): a file
/// that is damaged, from a newer Shello, or holds a record that breaks a rule is refused as a
/// whole, with a reason, and the database stays as it was.
struct ImportValidationTests {
    let test: TestDatabase
    var exports: ExportRepository { test.exports }

    init() throws {
        test = try TestDatabase()
    }

    /// Reads and imports `data`, as the app does once the user confirms.
    private func importData(_ data: Data) async throws {
        try await exports.importFile(try ExportFile(data: data))
    }

    @Test func sampleFileIsValid() throws {
        let file = try ExportFile(data: ExportSample.exportData())

        #expect(file.counts == RecordCounts(hosts: 3, groups: 2, tags: 7))
    }

    /// A file is read into memory at once, so one far larger than an export is refused unread.
    /// Spaces after the JSON keep it valid.
    @Test func fileLargerThanAnyExportIsRefused() throws {
        let sample = try ExportSample.exportData()
        let largest = sample + Data(repeating: 0x20, count: ExportFile.maximumByteCount - sample.count)

        #expect(try ExportFile(data: largest).counts.hosts == 3)
        #expect(throws: ImportError.tooLarge) {
            try ExportFile(data: largest + [0x20])
        }
    }

    // MARK: - Damaged files

    /// Cut off anywhere, for example by a transfer that stopped, a file is no longer JSON.
    @Test func truncatedFileIsRefusedAndTheDatabaseIsUnchanged() async throws {
        try await ExportSample.store(in: test.repository)
        let before = try await test.snapshot()
        let data = try ExportSample.exportData()

        for length in 0..<data.count {
            await #expect(throws: ImportError.unreadable, "cut off after \(length) bytes") {
                try await importData(data.prefix(length))
            }
        }

        #expect(try await test.snapshot() == before)
    }

    @Test(arguments: [
        Damage("text that is not JSON", replacing: "{", with: "Shello export {", error: .unreadable),
        // The decoder reads text only when it decodes it, and does not say where.
        Damage("bytes that are not text", replacing: "Homelab", withBytes: [0xC3, 0x28], error: .damaged(path: nil)),
        Damage("a number as text", replacing: #""port" : 22,"#, with: #""port" : "22","#, path: "hosts[0].port"),
        Damage("a missing value", replacing: #""address" : "2001:db8::21","#, with: "", path: "hosts[0].address"),
        Damage("a list that is not one", replacing: #""hosts" : ["#, with: #""hosts" : 1, "x" : ["#, path: "hosts"),
        Damage("an identifier that is not one", replacing: #"000000000001""#, with: #"1""#, path: "groups[0].id"),
        Damage(
            "a schema version that is not a number", replacing: #""schemaVersion" : 2"#,
            with: #""schemaVersion" : "2""#, path: "schemaVersion"),
        Damage(
            "schema version 0", replacing: #""schemaVersion" : 2"#, with: #""schemaVersion" : 0"#,
            path: "schemaVersion"),
        // Since version 2, every host has its tmux settings.
        Damage(
            "a host without auto-attach", replacing: #""tmuxAutoAttach" : true,"#, with: "",
            path: "hosts[0].tmuxAutoAttach"),
        Damage(
            "a host without its tmux session", replacing: #""tmuxSessionName" : "dev_work-2","#, with: "",
            path: "hosts[0].tmuxSessionName"),
        Damage(
            "auto-attach that is not true or false", replacing: #""tmuxAutoAttach" : true"#,
            with: #""tmuxAutoAttach" : "yes""#, path: "hosts[0].tmuxAutoAttach"),
        Damage(
            "a tmux session name that is no text", replacing: #""tmuxSessionName" : "dev_work-2""#,
            with: #""tmuxSessionName" : null"#, path: "hosts[0].tmuxSessionName"),
    ])
    func damagedFileIsRefusedAndTheDatabaseIsUnchanged(_ damage: Damage) async throws {
        try await ExportSample.store(in: test.repository)
        let before = try await test.snapshot()

        await #expect(throws: damage.error) {
            try await importData(damage.apply(to: ExportSample.exportData()))
        }

        #expect(try await test.snapshot() == before)
    }

    @Test func numberTooLargeForSwiftIsDamage() throws {
        let data = try Damage(
            "a number beyond a double", replacing: #""lastConnectedAt" : 800000000.0000001"#,
            with: #""lastConnectedAt" : 1e400"#, error: .damaged(path: nil)
        ).apply(to: ExportSample.exportData())

        let error = #expect(throws: ImportError.self) { try ExportFile(data: data) }

        guard case .damaged = error else {
            Issue.record("\(String(describing: error)) is not damage")
            return
        }
    }

    // MARK: - Files that are not exports

    @Test(arguments: [
        "{}", "[]", "null", "\"Shello\"", "42", #"{"format":"ch.shello.snippets","schemaVersion":1}"#,
        #"{"schemaVersion":1,"hosts":[],"groups":[],"tags":[]}"#, #"{"format":1,"schemaVersion":1}"#,
        #"[{"format":"ch.shello.export","schemaVersion":1}]"#,
    ])
    func jsonThatIsNotAShelloExportIsRefused(_ json: String) {
        #expect(throws: ImportError.notAnExport) {
            try ExportFile(data: Data(json.utf8))
        }
    }

    // MARK: - Newer schema versions

    /// A newer Shello may have added records or changed their shape; this version would leave out
    /// what it does not know, so it refuses the file and says to update.
    @Test(arguments: [
        #"{"format":"ch.shello.export","schemaVersion":3,"hosts":[],"groups":[],"tags":[]}"#,
        #"{"format":"ch.shello.export","schemaVersion":3,"snippets":[{"name":"uptime"}],"hosts":"elsewhere"}"#,
        #"{"format":"ch.shello.export","schemaVersion":99}"#,
    ])
    func fileFromANewerSchemaVersionIsRefused(_ json: String) async throws {
        try await ExportSample.store(in: test.repository)
        let before = try await test.snapshot()

        let error = await #expect(throws: ImportError.self) {
            try await importData(Data(json.utf8))
        }

        guard case .newerSchemaVersion(let version) = error else {
            Issue.record("\(String(describing: error)) is not a newer schema version")
            return
        }
        #expect(version > ExportFile.currentSchemaVersion)
        #expect(
            error?.description
                == "The file comes from a newer version of Shello. Update Shello, then import the file again.")
        #expect(try await test.snapshot() == before)
    }

    // MARK: - Records that break a rule

    @Test(arguments: Corruption.all)
    func recordThatBreaksARuleIsRefusedWithTheReason(_ corruption: Corruption) async throws {
        try await ExportSample.store(in: test.repository)
        let before = try await test.snapshot()

        let error = await #expect(throws: ImportError.self) {
            try await importData(corruption.apply())
        }

        guard case .invalidRecords(let problems) = error else {
            Issue.record("\(String(describing: error)) is not a list of problems")
            return
        }
        #expect(problems.contains(corruption.problem), "\(problems)")
        #expect(try await test.snapshot() == before)
    }

    /// Every record is checked, so that one error names every problem the user would have to fix.
    @Test func everyProblemIsListedAndTheFirstIsSaid() throws {
        let data = try Corruption.sample { format in
            format.hosts[0].port = 0
            format.hosts[2].address = "10.0.4"
            format.tags[0].name = ""
        }

        let error = #expect(throws: ImportError.self) { try ExportFile(data: data) }

        #expect(
            error
                == .invalidRecords([
                    "Tag 1 has no name.",
                    "The host “forge” has the port 0, but a port is from 1 to 65535.",
                    "The host “prod-api-01” has an address that isn’t a hostname, an IPv4 address or an IPv6 address.",
                ]))
        #expect(error?.description == "Tag 1 has no name. There are 2 more problems.")
    }
}

/// A change to the text of the sample export that damages it.
struct Damage: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let target: String
    let replacement: [UInt8]
    let error: ImportError

    init(_ description: String, replacing target: String, with replacement: String, error: ImportError) {
        self.init(description, replacing: target, withBytes: Array(replacement.utf8), error: error)
    }

    /// A damage the decoder finds at `path`.
    init(_ description: String, replacing target: String, with replacement: String, path: String) {
        self.init(description, replacing: target, with: replacement, error: .damaged(path: path))
    }

    /// Replaces `target` with `bytes`, which need not be text.
    init(_ description: String, replacing target: String, withBytes bytes: [UInt8], error: ImportError) {
        testDescription = description
        self.target = target
        replacement = bytes
        self.error = error
    }

    /// `data` with the first occurrence of the target replaced.
    func apply(to data: Data) throws -> Data {
        let range = try #require(data.firstRange(of: Data(target.utf8)), "\(target) is not in the sample")
        var damaged = data
        damaged.replaceSubrange(range, with: replacement)
        return damaged
    }
}

/// A change to one record of the sample export that breaks a rule, and the problem it causes. The
/// sample's records in file order: groups Homelab and Work; tags by colour name, Tag blue first;
/// hosts forge, Media PC 📺 and prod-api-01.
struct Corruption: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let change: @Sendable (inout ExportFormat) -> Void
    let problem: String

    func apply() throws -> Data {
        try Self.sample(change)
    }

    /// The sample export after `change`.
    static func sample(_ change: (inout ExportFormat) -> Void) throws -> Data {
        var format = try JSONDecoder().decode(ExportFormat.self, from: ExportSample.exportData())
        change(&format)
        return try JSONEncoder().encode(format)
    }

    static let sessionNameProblem =
        "The host “forge” has a tmux session name Shello can’t use: it takes 1 to 64 letters, digits, hyphens "
        + "and underscores, not starting with a hyphen."

    static let all: [Corruption] = [
        Corruption(
            testDescription: "a host without a name", change: { $0.hosts[0].name = " " }, problem: "Host 1 has no name."
        ),
        Corruption(
            testDescription: "a host without an address", change: { $0.hosts[0].address = "" },
            problem: "The host “forge” has an address that isn’t a hostname, an IPv4 address or an IPv6 address."),
        Corruption(
            testDescription: "an address with a space", change: { $0.hosts[0].address = "forge lan" },
            problem: "The host “forge” has an address that isn’t a hostname, an IPv4 address or an IPv6 address."),
        Corruption(
            testDescription: "port 0", change: { $0.hosts[0].port = 0 },
            problem: "The host “forge” has the port 0, but a port is from 1 to 65535."),
        Corruption(
            testDescription: "port 65536", change: { $0.hosts[0].port = 65536 },
            problem: "The host “forge” has the port 65536, but a port is from 1 to 65535."),
        Corruption(
            testDescription: "a negative port", change: { $0.hosts[0].port = -22 },
            problem: "The host “forge” has the port -22, but a port is from 1 to 65535."),
        Corruption(
            testDescription: "an unknown protocol", change: { $0.hosts[0].protocol = "telnet" },
            problem: "The host “forge” uses a protocol Shello doesn’t know: “telnet”."),
        Corruption(
            testDescription: "an unknown sign-in method", change: { $0.hosts[0].authMethod = "agent" },
            problem: "The host “forge” signs in with a method Shello doesn’t know: “agent”."),
        Corruption(
            testDescription: "an empty terminal type", change: { $0.hosts[0].terminalType = "" },
            problem: "The host “forge” has a terminal type that is empty or has spaces in it."),
        Corruption(
            testDescription: "a terminal type with a space", change: { $0.hosts[0].terminalType = "xterm 256color" },
            problem: "The host “forge” has a terminal type that is empty or has spaces in it."),
        Corruption(
            testDescription: "no keepalive interval", change: { $0.hosts[0].keepaliveIntervalMilliseconds = 0 },
            problem: "The host “forge” has a keepalive interval that isn’t longer than zero."),
        Corruption(
            testDescription: "a negative connect timeout", change: { $0.hosts[0].connectTimeoutMilliseconds = -5 },
            problem: "The host “forge” has a connect timeout that isn’t longer than zero."),
        Corruption(
            testDescription: "a last connection beyond the year 4000", change: { $0.hosts[0].lastConnectedAt = 1e300 },
            problem: "The host “forge” has a last connection time that isn’t a date."),
        Corruption(
            testDescription: "a group that is not in the file", change: { $0.hosts[0].groupID = UUID() },
            problem: "The host “forge” is in a group that isn’t in the file."),
        Corruption(
            testDescription: "a tag that is not in the file", change: { $0.hosts[0].tagIDs.append(UUID()) },
            problem: "The host “forge” has a tag that isn’t in the file."),
        Corruption(
            testDescription: "a null character in a host's notes", change: { $0.hosts[0].notes = "a\u{0}b" },
            problem: "The host “forge” has a null character in its text, which Shello can’t store."),
        Corruption(
            testDescription: "a null character in a host's name", change: { $0.hosts[0].name = "for\u{0}ge" },
            problem: "Host 1 has a null character in its text, which Shello can’t store."),
        Corruption(
            testDescription: "a tmux session name with a space", change: { $0.hosts[0].tmuxSessionName = "my work" },
            problem: Self.sessionNameProblem),
        Corruption(
            testDescription: "an empty tmux session name", change: { $0.hosts[0].tmuxSessionName = "" },
            problem: Self.sessionNameProblem),
        Corruption(
            testDescription: "a tmux session name that a shell would run",
            change: { $0.hosts[0].tmuxSessionName = "main'; rm -rf ~; '" }, problem: Self.sessionNameProblem),
        Corruption(
            testDescription: "a tmux session name that reads as an option",
            change: { $0.hosts[0].tmuxSessionName = "-d" }, problem: Self.sessionNameProblem),
        Corruption(
            testDescription: "two hosts with one identifier", change: { $0.hosts[1].id = $0.hosts[0].id },
            problem: "The host “Media PC 📺” has the same identifier as another host in the file."),
        Corruption(
            testDescription: "a group without a name", change: { $0.groups[0].name = "" },
            problem: "Group 1 has no name."),
        Corruption(
            testDescription: "a null character in a group's name", change: { $0.groups[0].name = "Home\u{0}" },
            problem: "Group 1 has a null character in its text, which Shello can’t store."),
        Corruption(
            testDescription: "two groups with one identifier", change: { $0.groups[1].id = $0.groups[0].id },
            problem: "The group “Work” has the same identifier as another group in the file."),
        Corruption(
            testDescription: "a tag without a name", change: { $0.tags[0].name = "\n" }, problem: "Tag 1 has no name."),
        Corruption(
            testDescription: "an unknown tag colour", change: { $0.tags[0].color = "pink" },
            problem: "The tag “Tag blue” has a colour Shello doesn’t know: “pink”."),
        Corruption(
            testDescription: "two tags with one identifier", change: { $0.tags[1].id = $0.tags[0].id },
            problem: "The tag “Tag gray” has the same identifier as another tag in the file."),
    ]
}
