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
            "a schema version that is not a number", replacing: #""schemaVersion" : 5"#,
            with: #""schemaVersion" : "4""#, path: "schemaVersion"),
        Damage(
            "schema version 0", replacing: #""schemaVersion" : 5"#, with: #""schemaVersion" : 0"#,
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
        // Since version 3, every host has its jump hosts.
        Damage(
            "a jump host that is not an identifier", replacing: #""00000000-0000-4000-8000-000000000199""#,
            with: #""bastion""#, path: "hosts[1].jumpHostIDs[1]"),
        Damage(
            "jump hosts that are not a list", replacing: #""jumpHostIDs" : ["#,
            with: #""jumpHostIDs" : "bastion", "x" : ["#, path: "hosts[0].jumpHostIDs"),
        // Since version 4, every host has its port forwards.
        Damage(
            "port forwards that are not a list", replacing: #""portForwards" : ["#,
            with: #""portForwards" : "socks", "x" : ["#, path: "hosts[0].portForwards"),
        Damage(
            "a port forward's port as text", replacing: #""localPort" : 15432"#, with: #""localPort" : "15432""#,
            path: "hosts[2].portForwards[0].localPort"),
        Damage(
            "a port forward without its switch", replacing: #""isEnabled" : false,"#, with: "",
            path: "hosts[2].portForwards[2].isEnabled"),
    ])
    func damagedFileIsRefusedAndTheDatabaseIsUnchanged(_ damage: Damage) async throws {
        try await ExportSample.store(in: test.repository)
        let before = try await test.snapshot()

        await #expect(throws: damage.error) {
            try await importData(damage.apply(to: ExportSample.exportData()))
        }

        #expect(try await test.snapshot() == before)
    }

    /// Since version 3, every host has its jump hosts, an empty list for none: a host without the
    /// key is damage, as a missing key is.
    @Test func hostWithoutItsJumpHostsIsDamage() throws {
        let data = try Corruption.sample { $0.hosts[0].jumpHostIDs = nil }

        #expect(throws: ImportError.damaged(path: "hosts[0].jumpHostIDs")) { try ExportFile(data: data) }
    }

    /// Since version 4, every host has its port forwards, an empty list for none: a host without the
    /// key is damage.
    @Test func hostWithoutItsPortForwardsIsDamage() throws {
        let data = try Corruption.sample { $0.hosts[2].portForwards = nil }

        #expect(throws: ImportError.damaged(path: "hosts[2].portForwards")) { try ExportFile(data: data) }
    }

    /// Version 3 had no port forwards: a version 3 file that has them anyway is read without them.
    @Test func version3FileIsReadWithoutPortForwards() throws {
        let data = try Corruption.sample { $0.schemaVersion = 3 }

        let file = try ExportFile(data: data)

        #expect(file.hosts.allSatisfy { $0.portForwards.isEmpty })
        #expect(file.hosts.contains { !$0.jumpHostIDs.isEmpty })
    }

    /// Since version 4, every local and dynamic forward has the port it listens on, and since
    /// version 5 every remote forward the port the server listens on: one without it is damage.
    @Test(arguments: [
        (0, "localPort"), (2, "localPort"), (3, "serverPort"),
    ])
    func forwardWithoutItsPortIsDamage(index: Int, key: String) throws {
        let data = try Corruption.sample { format in
            if key == "localPort" {
                format.hosts[2].portForwards?[index].localPort = nil
            } else {
                format.hosts[2].portForwards?[index].serverPort = nil
            }
        }

        #expect(throws: ImportError.damaged(path: "hosts[2].portForwards[\(index)].\(key)")) {
            try ExportFile(data: data)
        }
    }

    /// A remote forward without a bind address listens on the server's loopback, as one with an
    /// empty one does.
    @Test func remoteForwardWithoutABindAddressListensOnTheLoopback() throws {
        let data = try Corruption.sample { $0.hosts[2].portForwards?[3].bindAddress = nil }

        let file = try ExportFile(data: data)

        #expect(file.hosts[2].portForwards[3].bindAddress == "")
    }

    /// A dynamic forward has no destination: one in the file is left out.
    @Test func dynamicForwardIsReadWithoutADestination() throws {
        let data = try Corruption.sample { format in
            format.hosts[2].portForwards?[2].destinationAddress = "db.internal"
            format.hosts[2].portForwards?[2].destinationPort = 5432
        }

        let file = try ExportFile(data: data)

        #expect(file.hosts[2].portForwards[2].kind == .dynamic)
    }

    /// Version 2 had no jump hosts: a version 2 file that has them anyway is read without them.
    @Test func version2FileIsReadWithoutJumpHosts() throws {
        let data = try Corruption.sample { $0.schemaVersion = 2 }

        let file = try ExportFile(data: data)

        let jumpHostIDs = file.hosts.flatMap(\.jumpHostIDs)
        #expect(jumpHostIDs.isEmpty)
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
        #"{"format":"ch.shello.export","schemaVersion":6,"hosts":[],"groups":[],"tags":[]}"#,
        #"{"format":"ch.shello.export","schemaVersion":6,"snippets":[{"name":"uptime"}],"hosts":"elsewhere"}"#,
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
            testDescription: "a host that is its own jump host", change: { $0.hosts[0].jumpHostIDs = [$0.hosts[0].id] },
            problem: "The host “forge” has itself as a jump host."),
        Corruption(
            testDescription: "the same jump host twice",
            change: { $0.hosts[1].jumpHostIDs?.append(ExportSample.id("000000000101")) },
            problem: "The host “Media PC 📺” has the same jump host twice."),
        Corruption(
            testDescription: "more jump hosts than a route can have",
            change: { $0.hosts[0].jumpHostIDs = (0..<9).map { _ in UUID() } },
            problem: "The host “forge” has more than 8 jump hosts, the most a route can have."),
        Corruption(
            testDescription: "a port forward on port 0", change: { $0.hosts[2].portForwards?[0].localPort = 0 },
            problem: "The host “prod-api-01” has a port forward on port 0, but a port is from 1 to 65535."),
        Corruption(
            testDescription: "a port forward on port 65536",
            change: { $0.hosts[2].portForwards?[2].localPort = 65536 },
            problem: "The host “prod-api-01” has a port forward on port 65536, but a port is from 1 to 65535."),
        Corruption(
            testDescription: "a remote port forward in a version 4 file, which version 4 did not know",
            change: { $0.schemaVersion = 4 },
            problem: "The host “prod-api-01” has a port forward of a kind Shello doesn’t know: “remote”."),
        Corruption(
            testDescription: "a port forward of an unknown kind",
            change: { $0.hosts[2].portForwards?[0].kind = "reverse" },
            problem: "The host “prod-api-01” has a port forward of a kind Shello doesn’t know: “reverse”."),
        Corruption(
            testDescription: "a remote port forward on the server's port 0",
            change: { $0.hosts[2].portForwards?[3].serverPort = 0 },
            problem: "The host “prod-api-01” has a port forward on port 0, but a port is from 1 to 65535."),
        Corruption(
            testDescription: "a remote port forward with a bind address with a space",
            change: { $0.hosts[2].portForwards?[3].bindAddress = "0.0.0.0 1" },
            problem:
                "The host “prod-api-01” has a remote port forward whose bind address isn’t empty, *, a hostname, an "
                + "IPv4 address or an IPv6 address."),
        Corruption(
            testDescription: "a remote port forward without a destination",
            change: { $0.hosts[2].portForwards?[3].destinationPort = nil },
            problem: "The host “prod-api-01” has a remote port forward without a destination."),
        Corruption(
            testDescription: "a null character in a remote port forward's bind address",
            change: { $0.hosts[2].portForwards?[3].bindAddress = "host\u{0}" },
            problem: "The host “prod-api-01” has a null character in its text, which Shello can’t store."),
        Corruption(
            testDescription: "two remote port forwards that are on with one server port",
            change: { format in
                format.hosts[2].portForwards?[4].isEnabled = true
                format.hosts[2].portForwards?[4].serverPort = 8080
            },
            problem:
                "The host “prod-api-01” has two remote port forwards that are on and have the server listen on port "
                + "8080."),
        Corruption(
            testDescription: "a local port forward without a destination",
            change: { $0.hosts[2].portForwards?[0].destinationAddress = nil },
            problem: "The host “prod-api-01” has a local port forward without a destination."),
        Corruption(
            testDescription: "a port forward to an address with a space",
            change: { $0.hosts[2].portForwards?[0].destinationAddress = "db internal" },
            problem:
                "The host “prod-api-01” has a port forward to an address that isn’t a hostname, an IPv4 address or "
                + "an IPv6 address."),
        Corruption(
            testDescription: "a port forward to port 0", change: { $0.hosts[2].portForwards?[1].destinationPort = 0 },
            problem: "The host “prod-api-01” has a port forward to the port 0, but a port is from 1 to 65535."),
        Corruption(
            testDescription: "a null character in a port forward's name",
            change: { $0.hosts[2].portForwards?[0].name = "D\u{0}b" },
            problem: "The host “prod-api-01” has a null character in its text, which Shello can’t store."),
        Corruption(
            testDescription: "two port forwards with one identifier",
            change: { $0.hosts[2].portForwards?[1].id = ExportSample.id("000000000301") },
            problem: "The host “prod-api-01” has two port forwards with the same identifier."),
        Corruption(
            testDescription: "two port forwards that are on with one port",
            change: { $0.hosts[2].portForwards?[1].localPort = 15432 },
            problem: "The host “prod-api-01” has two port forwards that are on and listen on port 15432."),
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
