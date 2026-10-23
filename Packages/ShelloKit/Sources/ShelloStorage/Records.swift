import Foundation
import GRDB
import ShelloModel

// The rows behind the model types. Each synced field has a modification time next to it (`Schema`).

/// A row type. Dates are stored as `timeIntervalSinceReferenceDate`, which keeps every `Date`
/// exactly as it was; GRDB's default text format keeps milliseconds only.
protocol StoredRecord: Codable, FetchableRecord, PersistableRecord {}

extension StoredRecord {
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }
}

/// A row that deleting turns into a tombstone instead of removing it.
protocol Tombstoned {
    var deletedAt: Date? { get set }
    var deletedAtModifiedAt: Date { get set }
}

extension Tombstoned {
    /// Makes a tombstone a live row again, at `now`. A live row stays as it is.
    mutating func undoDeletion(at now: Date) {
        guard deletedAt != nil else { return }
        deletedAt = nil
        deletedAtModifiedAt = now
    }
}

// MARK: - Host

struct HostRecord: StoredRecord, Tombstoned, Identifiable {
    static let databaseTableName = "host"

    var id: UUID
    var name: String
    var nameModifiedAt: Date
    var address: String
    var addressModifiedAt: Date
    var port: UInt16
    var portModifiedAt: Date
    var `protocol`: String
    var protocolModifiedAt: Date
    var username: String
    var usernameModifiedAt: Date
    var authMethod: String
    var authMethodModifiedAt: Date
    var sshKeyID: UUID?
    var sshKeyIDModifiedAt: Date
    var groupID: UUID?
    var groupIDModifiedAt: Date
    var tagsModifiedAt: Date
    var notes: String
    var notesModifiedAt: Date
    var startupCommand: String
    var startupCommandModifiedAt: Date
    var tmuxAutoAttach: Bool
    var tmuxAutoAttachModifiedAt: Date
    var tmuxSessionName: String
    var tmuxSessionNameModifiedAt: Date
    var terminalType: String
    var terminalTypeModifiedAt: Date
    /// Milliseconds.
    var keepaliveInterval: Int64
    var keepaliveIntervalModifiedAt: Date
    /// Milliseconds.
    var connectTimeout: Int64
    var connectTimeoutModifiedAt: Date
    var isFavorite: Bool
    var isFavoriteModifiedAt: Date
    var lastConnectedAt: Date?
    var lastConnectedAtModifiedAt: Date
    var deletedAt: Date?
    var deletedAtModifiedAt: Date

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let address = Column(CodingKeys.address)
        static let username = Column(CodingKeys.username)
        static let isFavorite = Column(CodingKeys.isFavorite)
        static let lastConnectedAt = Column(CodingKeys.lastConnectedAt)
        static let deletedAt = Column(CodingKeys.deletedAt)
    }

    /// A new host's row, with every field modified at `now`.
    init(_ host: Host, modifiedAt now: Date) {
        id = host.id
        name = host.name
        nameModifiedAt = now
        address = host.address
        addressModifiedAt = now
        port = host.port
        portModifiedAt = now
        self.protocol = host.protocol.storedValue
        protocolModifiedAt = now
        username = host.username
        usernameModifiedAt = now
        authMethod = host.authMethod.storedValue
        authMethodModifiedAt = now
        sshKeyID = host.sshKeyID
        sshKeyIDModifiedAt = now
        groupID = host.groupID
        groupIDModifiedAt = now
        tagsModifiedAt = now
        notes = host.notes
        notesModifiedAt = now
        startupCommand = host.startupCommand
        startupCommandModifiedAt = now
        tmuxAutoAttach = host.tmuxAutoAttach
        tmuxAutoAttachModifiedAt = now
        tmuxSessionName = host.tmuxSessionName
        tmuxSessionNameModifiedAt = now
        terminalType = host.terminalType
        terminalTypeModifiedAt = now
        keepaliveInterval = host.keepaliveInterval.storedMilliseconds
        keepaliveIntervalModifiedAt = now
        connectTimeout = host.connectTimeout.storedMilliseconds
        connectTimeoutModifiedAt = now
        isFavorite = host.isFavorite
        isFavoriteModifiedAt = now
        lastConnectedAt = host.lastConnectedAt
        lastConnectedAtModifiedAt = now
        deletedAt = nil
        deletedAtModifiedAt = now
    }

    /// Writes the fields where `host` differs from `current`, the host as the row reads now, and
    /// moves their modification times to `now`. Comparing with what a read returns, rather than
    /// with the row, keeps a deleted group in the row when the caller saves a host it read without
    /// it, so that undoing the group's deletion brings the membership back.
    mutating func apply(_ host: Host, changedFrom current: Host, at now: Date) {
        if host.name != current.name {
            name = host.name
            nameModifiedAt = now
        }
        if host.address != current.address {
            address = host.address
            addressModifiedAt = now
        }
        if host.port != current.port {
            port = host.port
            portModifiedAt = now
        }
        if host.protocol != current.protocol {
            self.protocol = host.protocol.storedValue
            protocolModifiedAt = now
        }
        if host.username != current.username {
            username = host.username
            usernameModifiedAt = now
        }
        if host.authMethod != current.authMethod {
            authMethod = host.authMethod.storedValue
            authMethodModifiedAt = now
        }
        if host.sshKeyID != current.sshKeyID {
            sshKeyID = host.sshKeyID
            sshKeyIDModifiedAt = now
        }
        if host.groupID != current.groupID {
            groupID = host.groupID
            groupIDModifiedAt = now
        }
        if host.tagIDs != current.tagIDs {
            tagsModifiedAt = now
        }
        if host.notes != current.notes {
            notes = host.notes
            notesModifiedAt = now
        }
        if host.startupCommand != current.startupCommand {
            startupCommand = host.startupCommand
            startupCommandModifiedAt = now
        }
        if host.tmuxAutoAttach != current.tmuxAutoAttach {
            tmuxAutoAttach = host.tmuxAutoAttach
            tmuxAutoAttachModifiedAt = now
        }
        if host.tmuxSessionName != current.tmuxSessionName {
            tmuxSessionName = host.tmuxSessionName
            tmuxSessionNameModifiedAt = now
        }
        if host.terminalType != current.terminalType {
            terminalType = host.terminalType
            terminalTypeModifiedAt = now
        }
        if host.keepaliveInterval != current.keepaliveInterval {
            keepaliveInterval = host.keepaliveInterval.storedMilliseconds
            keepaliveIntervalModifiedAt = now
        }
        if host.connectTimeout != current.connectTimeout {
            connectTimeout = host.connectTimeout.storedMilliseconds
            connectTimeoutModifiedAt = now
        }
        if host.isFavorite != current.isFavorite {
            isFavorite = host.isFavorite
            isFavoriteModifiedAt = now
        }
        if host.lastConnectedAt != current.lastConnectedAt {
            lastConnectedAt = host.lastConnectedAt
            lastConnectedAtModifiedAt = now
        }
    }

    /// The host this row holds. Its group and tags are passed in, because a deleted group or tag
    /// no longer counts.
    func host(groupID: HostGroup.ID?, tagIDs: Set<Tag.ID>) throws -> Host {
        Host(
            id: id,
            name: name,
            address: address,
            port: port,
            protocol: try HostProtocol(storedValue: self.protocol, column: "protocol"),
            username: username,
            authMethod: try AuthMethod(storedValue: authMethod, column: "authMethod"),
            sshKeyID: sshKeyID,
            groupID: groupID,
            tagIDs: tagIDs,
            notes: notes,
            startupCommand: startupCommand,
            tmuxAutoAttach: tmuxAutoAttach,
            tmuxSessionName: tmuxSessionName,
            terminalType: terminalType,
            keepaliveInterval: .milliseconds(keepaliveInterval),
            connectTimeout: .milliseconds(connectTimeout),
            isFavorite: isFavorite,
            lastConnectedAt: lastConnectedAt
        )
    }
}

// MARK: - Group

struct HostGroupRecord: StoredRecord, Tombstoned, Identifiable {
    static let databaseTableName = "hostGroup"

    var id: UUID
    var name: String
    var nameModifiedAt: Date
    var deletedAt: Date?
    var deletedAtModifiedAt: Date

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let deletedAt = Column(CodingKeys.deletedAt)
    }

    init(_ group: HostGroup, modifiedAt now: Date) {
        id = group.id
        name = group.name
        nameModifiedAt = now
        deletedAt = nil
        deletedAtModifiedAt = now
    }

    /// Writes the fields where `group` differs, and moves their modification times to `now`.
    mutating func apply(_ group: HostGroup, at now: Date) {
        if group.name != name {
            name = group.name
            nameModifiedAt = now
        }
    }

    var group: HostGroup {
        HostGroup(id: id, name: name)
    }
}

// MARK: - Tag

struct TagRecord: StoredRecord, Tombstoned, Identifiable {
    static let databaseTableName = "tag"

    var id: UUID
    var name: String
    var nameModifiedAt: Date
    var color: String
    var colorModifiedAt: Date
    var deletedAt: Date?
    var deletedAtModifiedAt: Date

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let deletedAt = Column(CodingKeys.deletedAt)
    }

    init(_ tag: Tag, modifiedAt now: Date) {
        id = tag.id
        name = tag.name
        nameModifiedAt = now
        color = tag.color.storedValue
        colorModifiedAt = now
        deletedAt = nil
        deletedAtModifiedAt = now
    }

    /// Writes the fields where `tag` differs, and moves their modification times to `now`.
    mutating func apply(_ tag: Tag, at now: Date) {
        if tag.name != name {
            name = tag.name
            nameModifiedAt = now
        }
        if tag.color.storedValue != color {
            color = tag.color.storedValue
            colorModifiedAt = now
        }
    }

    func tag() throws -> Tag {
        Tag(id: id, name: name, color: try Tag.Color(storedValue: color, column: "color"))
    }
}

// MARK: - Host tags

/// One of a host's tags. The rows of a host are its `tags` field, replaced as a whole.
struct HostTagRecord: StoredRecord {
    static let databaseTableName = "hostTag"

    var hostID: UUID
    var tagID: UUID

    enum Columns {
        static let hostID = Column(CodingKeys.hostID)
        static let tagID = Column(CodingKeys.tagID)
    }
}

// MARK: - Host keys

/// The host key trusted for one server, which the server's address and port identify.
struct HostKeyRecord: StoredRecord {
    static let databaseTableName = "hostKey"

    /// The server's address, in lowercase (`Server`).
    var address: String
    var port: UInt16
    var algorithm: String
    /// The key in SSH's wire format.
    var key: Data
    var fingerprint: String
    var trustedAt: Date

    enum Columns {
        static let address = Column(CodingKeys.address)
        static let port = Column(CodingKeys.port)
    }

    init(_ key: HostKey, of server: Server, trustedAt: Date) {
        address = server.address
        port = server.port
        algorithm = key.algorithm
        self.key = key.wireRepresentation
        fingerprint = key.fingerprint
        self.trustedAt = trustedAt
    }

    var trustedHostKey: TrustedHostKey {
        TrustedHostKey(
            key: HostKey(algorithm: algorithm, wireRepresentation: key, fingerprint: fingerprint),
            trustedAt: trustedAt)
    }
}

// MARK: - Stored values

/// A model enum stored as text. The stored values are part of the database format: they never change.
protocol StoredEnum: CaseIterable {
    var storedValue: String { get }
}

extension StoredEnum {
    init(storedValue: String, column: String) throws {
        guard let value = Self.allCases.first(where: { $0.storedValue == storedValue }) else {
            throw UnknownStoredValueError(column: column, value: storedValue)
        }
        self = value
    }
}

/// A stored value this version of Shello does not know, for example one written by a newer version.
struct UnknownStoredValueError: Error, CustomStringConvertible {
    let column: String
    let value: String

    var description: String {
        "Unknown value \"\(value)\" in database column \(column)."
    }
}

extension HostProtocol: StoredEnum {
    var storedValue: String {
        switch self {
        case .ssh: "ssh"
        case .mosh: "mosh"
        case .vnc: "vnc"
        }
    }
}

extension AuthMethod: StoredEnum {
    var storedValue: String {
        switch self {
        case .sshKey: "sshKey"
        case .password: "password"
        case .keyboardInteractive: "keyboardInteractive"
        }
    }
}

extension Tag.Color: StoredEnum {
    var storedValue: String {
        switch self {
        case .red: "red"
        case .orange: "orange"
        case .yellow: "yellow"
        case .green: "green"
        case .blue: "blue"
        case .purple: "purple"
        case .gray: "gray"
        }
    }
}

extension Duration {
    /// Whole milliseconds, how the database stores a duration. Saturates at the limits of `Int64`.
    var storedMilliseconds: Int64 {
        let (milliseconds, overflow) = components.seconds.multipliedReportingOverflow(by: 1000)
        let (total, sumOverflow) = milliseconds.addingReportingOverflow(
            components.attoseconds / 1_000_000_000_000_000)
        guard !overflow, !sumOverflow else { return self < .zero ? .min : .max }
        return total
    }
}
