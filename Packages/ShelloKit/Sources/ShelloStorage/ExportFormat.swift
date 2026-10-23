import Foundation
import ShelloModel

/// The JSON of an export file, schema version 2, which reads version 1 too. docs/spec/EXPORT.md
/// describes the format; these types define it. The format is stable: a file that one version of
/// Shello writes, every later version reads. A change to it is a new schema version
/// (`ExportFile.currentSchemaVersion`), so that an older Shello refuses the file instead of leaving
/// out what it does not know.
///
/// The keys are the names of the stored properties, and enum values the strings the database
/// stores (`StoredEnum`); both never change. Optional values are left out when they have none.
/// Times are seconds since 2001-01-01T00:00:00Z, as the database stores them, so that they read
/// back exactly; durations are whole milliseconds.
struct ExportFormat: Codable {
    /// Marks the file as a Shello export, whatever its version.
    static let formatIdentifier = "ch.shello.export"

    var format: String
    var schemaVersion: Int
    var groups: [Group]
    var tags: [Tag]
    var hosts: [Host]

    struct Group: Codable {
        var id: UUID
        var name: String
    }

    struct Tag: Codable {
        var id: UUID
        var name: String
        /// One of the tag palette's colours: `red`, `orange`, `yellow`, `green`, `blue`, `purple`
        /// or `gray`.
        var color: String
    }

    /// A host. It refers to its SSH key, group and tags by identifier; passwords and SSH keys are
    /// never part of a host (README section 13).
    struct Host: Codable {
        var id: UUID
        var name: String
        var address: String
        var port: Int
        /// `ssh`, `mosh` or `vnc`.
        var `protocol`: String
        var username: String
        /// `sshKey`, `password` or `keyboardInteractive`.
        var authMethod: String
        /// The SSH key on the device that made the export. The key itself is never exported.
        var sshKeyID: UUID?
        var groupID: UUID?
        var tagIDs: [UUID]
        var notes: String
        var startupCommand: String
        /// Whether the host attaches its tmux session (README section 8). Since schema version 2,
        /// where every host has it; a host of version 1 has it off.
        var tmuxAutoAttach: Bool?
        /// The tmux session the host attaches. Since schema version 2, where every host has it; a
        /// host of version 1 attaches `main`.
        var tmuxSessionName: String?
        var terminalType: String
        var keepaliveIntervalMilliseconds: Int64
        var connectTimeoutMilliseconds: Int64
        var isFavorite: Bool
        /// Seconds since 2001-01-01T00:00:00Z.
        var lastConnectedAt: Double?
    }

    /// The keys every version has, read before the rest so that a file from a newer version is
    /// refused with a clear reason rather than for a shape this version does not know.
    struct Header: Decodable {
        var format: String?
        var schemaVersion: Int?

        private enum CodingKeys: String, CodingKey {
            case format
            case schemaVersion
        }

        /// Takes a value of the wrong type as missing: the file is then not an export, or damaged.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try? container.decodeIfPresent(String.self, forKey: .format)
            schemaVersion = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        }
    }
}

// MARK: - Writing

extension ExportFormat {
    init(_ file: ExportFile) {
        format = Self.formatIdentifier
        schemaVersion = ExportFile.currentSchemaVersion
        groups = file.groups.map { Group(id: $0.id, name: $0.name) }
        tags = file.tags.map { Tag(id: $0.id, name: $0.name, color: $0.color.storedValue) }
        hosts = file.hosts.map(Host.init)
    }
}

extension ExportFormat.Host {
    init(_ host: ShelloModel.Host) {
        id = host.id
        name = host.name
        address = host.address
        port = Int(host.port)
        self.protocol = host.protocol.storedValue
        username = host.username
        authMethod = host.authMethod.storedValue
        sshKeyID = host.sshKeyID
        groupID = host.groupID
        // Sorted, so that the same host always exports the same way.
        tagIDs = host.tagIDs.sorted { $0.uuidString < $1.uuidString }
        notes = host.notes
        startupCommand = host.startupCommand
        tmuxAutoAttach = host.tmuxAutoAttach
        tmuxSessionName = host.tmuxSessionName
        terminalType = host.terminalType
        keepaliveIntervalMilliseconds = host.keepaliveInterval.storedMilliseconds
        connectTimeoutMilliseconds = host.connectTimeout.storedMilliseconds
        isFavorite = host.isFavorite
        lastConnectedAt = host.lastConnectedAt?.timeIntervalSinceReferenceDate
    }
}

// MARK: - Reading

extension ExportFormat {
    /// The records, checked against the rules every host, group and tag in Shello follows: the
    /// host editor's, and what the database needs. Every record is checked, so that the error lists
    /// every problem, and a file with a problem is not imported at all.
    func file() throws(ImportError) -> ExportFile {
        // From version 2 on every host has its tmux settings, and a host without them is damage, as
        // a missing key is. Version 1 had none: its hosts get the defaults.
        if schemaVersion >= 2 {
            for (index, host) in hosts.enumerated() {
                if host.tmuxAutoAttach == nil { throw .damaged(path: "hosts[\(index)].tmuxAutoAttach") }
                if host.tmuxSessionName == nil { throw .damaged(path: "hosts[\(index)].tmuxSessionName") }
            }
        }
        var problems: [String] = []
        var checkedGroups: [HostGroup] = []
        for (index, group) in groups.enumerated() {
            if let group = group.checked(position: index + 1, problems: &problems) {
                checkedGroups.append(group)
            }
        }
        var checkedTags: [ShelloModel.Tag] = []
        for (index, tag) in tags.enumerated() {
            if let tag = tag.checked(position: index + 1, problems: &problems) {
                checkedTags.append(tag)
            }
        }
        let groupIDs = Set(groups.map(\.id))
        let tagIDs = Set(tags.map(\.id))
        var checkedHosts: [ShelloModel.Host] = []
        for (index, host) in hosts.enumerated() {
            if let host = host.checked(
                position: index + 1, schemaVersion: schemaVersion, groupIDs: groupIDs, tagIDs: tagIDs,
                problems: &problems)
            {
                checkedHosts.append(host)
            }
        }
        problems += Self.duplicates(kind: "group", groups.map { (id: $0.id, name: $0.name) })
        problems += Self.duplicates(kind: "tag", tags.map { (id: $0.id, name: $0.name) })
        problems += Self.duplicates(kind: "host", hosts.map { (id: $0.id, name: $0.name) })
        guard problems.isEmpty else { throw .invalidRecords(problems) }
        return ExportFile(groups: checkedGroups, tags: checkedTags, hosts: checkedHosts)
    }

    /// A problem for each identifier that more than one record of `kind` has: the file would not
    /// say which of them to import. It names the second record with the identifier.
    private static func duplicates(kind: String, _ records: [(id: UUID, name: String)]) -> [String] {
        var seen: Set<UUID> = []
        var reported: Set<UUID> = []
        var problems: [String] = []
        for (index, record) in records.enumerated() {
            if seen.contains(record.id), !reported.contains(record.id) {
                reported.insert(record.id)
                let name = RecordName(kind: kind, position: index + 1, name: record.name)
                problems.append("\(name.atStart) has the same identifier as another \(kind) in the file.")
            }
            seen.insert(record.id)
        }
        return problems
    }
}

extension ExportFormat.Group {
    fileprivate func checked(position: Int, problems: inout [String]) -> HostGroup? {
        let label = RecordName(kind: "group", position: position, name: name)
        let count = problems.count
        if name.isBlank { problems.append("\(label.atStart) has no name.") }
        if name.hasNullCharacter { problems.append(label.nullCharacterProblem) }
        guard problems.count == count else { return nil }
        return HostGroup(id: id, name: name)
    }
}

extension ExportFormat.Tag {
    fileprivate func checked(position: Int, problems: inout [String]) -> ShelloModel.Tag? {
        let label = RecordName(kind: "tag", position: position, name: name)
        let count = problems.count
        if name.isBlank { problems.append("\(label.atStart) has no name.") }
        if name.hasNullCharacter { problems.append(label.nullCharacterProblem) }
        let tagColor = try? ShelloModel.Tag.Color(storedValue: color, column: "color")
        if tagColor == nil { problems.append("\(label.atStart) has a colour Shello doesn’t know: “\(color)”.") }
        guard problems.count == count, let tagColor else { return nil }
        return ShelloModel.Tag(id: id, name: name, color: tagColor)
    }
}

extension ExportFormat.Host {
    fileprivate func checked(
        position: Int, schemaVersion: Int, groupIDs: Set<UUID>, tagIDs fileTagIDs: Set<UUID>, problems: inout [String]
    ) -> ShelloModel.Host? {
        let label = RecordName(kind: "host", position: position, name: name)
        let count = problems.count
        if name.isBlank { problems.append("\(label.atStart) has no name.") }
        if [name, address, username, notes, startupCommand, terminalType].contains(where: \.hasNullCharacter) {
            problems.append(label.nullCharacterProblem)
        }
        if AddressKind(of: address) == nil {
            problems.append(
                "\(label.atStart) has an address that isn’t a hostname, an IPv4 address or an IPv6 address.")
        }
        let validPort = UInt16(exactly: port).flatMap { ShelloModel.Host.validPorts.contains($0) ? $0 : nil }
        if validPort == nil { problems.append("\(label.atStart) has the port \(port), but a port is from 1 to 65535.") }
        let hostProtocol = try? HostProtocol(storedValue: self.protocol, column: "protocol")
        if hostProtocol == nil {
            problems.append("\(label.atStart) uses a protocol Shello doesn’t know: “\(self.protocol)”.")
        }
        let method = try? AuthMethod(storedValue: authMethod, column: "authMethod")
        if method == nil {
            problems.append("\(label.atStart) signs in with a method Shello doesn’t know: “\(authMethod)”.")
        }
        if terminalType.isEmpty || terminalType.contains(where: \.isWhitespace) {
            problems.append("\(label.atStart) has a terminal type that is empty or has spaces in it.")
        }
        if keepaliveIntervalMilliseconds <= 0 {
            problems.append("\(label.atStart) has a keepalive interval that isn’t longer than zero.")
        }
        if connectTimeoutMilliseconds <= 0 {
            problems.append("\(label.atStart) has a connect timeout that isn’t longer than zero.")
        }
        let lastConnection = lastConnectedAt.map(Date.init(timeIntervalSinceReferenceDate:))
        if let lastConnection, !(Date.distantPast...Date.distantFuture).contains(lastConnection) {
            problems.append("\(label.atStart) has a last connection time that isn’t a date.")
        }
        if let groupID, !groupIDs.contains(groupID) {
            problems.append("\(label.atStart) is in a group that isn’t in the file.")
        }
        if !fileTagIDs.isSuperset(of: tagIDs) {
            problems.append("\(label.atStart) has a tag that isn’t in the file.")
        }
        // A version 1 file has no tmux settings: its hosts get the defaults. From version 2 on,
        // `file()` made sure that every host has them.
        let isVersion1 = schemaVersion < 2
        let autoAttach = isVersion1 ? false : tmuxAutoAttach ?? false
        let sessionName = (isVersion1 ? nil : tmuxSessionName) ?? ShelloModel.Host.defaultTmuxSessionName
        if TmuxSessionName(sessionName) == nil {
            problems.append(
                "\(label.atStart) has a tmux session name Shello can’t use: it takes 1 to 64 letters, digits, "
                    + "hyphens and underscores, not starting with a hyphen.")
        }
        guard problems.count == count, let validPort, let hostProtocol, let method else { return nil }
        return ShelloModel.Host(
            id: id,
            name: name,
            address: address,
            port: validPort,
            protocol: hostProtocol,
            username: username,
            authMethod: method,
            sshKeyID: sshKeyID,
            groupID: groupID,
            tagIDs: Set(tagIDs),
            notes: notes,
            startupCommand: startupCommand,
            tmuxAutoAttach: autoAttach,
            tmuxSessionName: sessionName,
            terminalType: terminalType,
            keepaliveInterval: .milliseconds(keepaliveIntervalMilliseconds),
            connectTimeout: .milliseconds(connectTimeoutMilliseconds),
            isFavorite: isFavorite,
            lastConnectedAt: lastConnection
        )
    }
}

/// How a problem names a record: by its name in quotes, or by its position in the file when the
/// name cannot be shown.
private struct RecordName {
    let kind: String
    let position: Int
    let name: String

    /// "The host “nas”", or "Host 3".
    var atStart: String {
        isShowable ? "The \(kind) “\(name)”" : "\(kind.prefix(1).uppercased())\(kind.dropFirst()) \(position)"
    }

    var nullCharacterProblem: String {
        "\(atStart) has a null character in its text, which Shello can’t store."
    }

    private var isShowable: Bool { !name.isBlank && !name.hasNullCharacter }
}

extension String {
    fileprivate var isBlank: Bool {
        allSatisfy(\.isWhitespace)
    }

    /// SQLite stores such text, but GRDB reads it back only up to the null character.
    fileprivate var hasNullCharacter: Bool {
        unicodeScalars.contains("\0")
    }
}
