import Foundation
import ShelloModel

/// An export: all of Shello's non-secret data as one JSON file (README section 15). It holds the
/// hosts, groups and tags; snippets, presets and settings join it in later schema versions. It never
/// holds a secret: a host refers to its SSH key by identifier, and passwords and SSH keys live in the
/// Keychain or the Secure Enclave only (README section 13).
///
/// `ExportRepository` makes one from the database and imports one into it. A file read with
/// `init(data:)` has been checked completely, so importing it cannot fail on its contents.
/// docs/spec/EXPORT.md describes the format, and `ExportFormat` defines it.
public struct ExportFile: Hashable, Sendable {
    /// The schema version Shello writes, and the newest one it reads.
    public static let currentSchemaVersion = 1

    /// The largest file Shello reads as an export, in bytes: room for tens of thousands of hosts,
    /// and small enough to read into memory at once.
    public static let maximumByteCount = 16 * 1024 * 1024

    /// The groups, in the file's order: by name in a file Shello wrote.
    public let groups: [HostGroup]
    /// The tags, in the file's order: by name in a file Shello wrote.
    public let tags: [Tag]
    /// The hosts, in the file's order: by name in a file Shello wrote. Their groups and tags are in
    /// `groups` and `tags`.
    public let hosts: [Host]

    init(groups: [HostGroup], tags: [Tag], hosts: [Host]) {
        self.groups = groups
        self.tags = tags
        self.hosts = hosts
    }

    /// Reads an export file and checks all of it.
    /// - Throws: `ImportError` if the data is not an export this version of Shello can import.
    public init(data: Data) throws(ImportError) {
        guard data.count <= Self.maximumByteCount else { throw .tooLarge }
        let decoder = JSONDecoder()
        let header: ExportFormat.Header
        do {
            header = try decoder.decode(ExportFormat.Header.self, from: data)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
            throw .unreadable
        } catch {
            throw .notAnExport
        }
        guard header.format == ExportFormat.formatIdentifier else { throw .notAnExport }
        guard let schemaVersion = header.schemaVersion, schemaVersion >= 1 else {
            throw .damaged(path: "schemaVersion")
        }
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw .newerSchemaVersion(schemaVersion)
        }
        let format: ExportFormat
        do {
            format = try decoder.decode(ExportFormat.self, from: data)
        } catch let error as DecodingError {
            throw .damaged(path: error.path)
        } catch {
            throw .unreadable
        }
        self = try format.file()
    }

    /// The file's JSON, in the current schema version. The same data always gives the same file.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ExportFormat(self))
    }

    /// How many hosts, groups and tags the file holds.
    public var counts: RecordCounts {
        RecordCounts(hosts: hosts.count, groups: groups.count, tags: tags.count)
    }
}

/// A number of hosts, groups and tags.
public struct RecordCounts: Hashable, Sendable {
    public var hosts: Int
    public var groups: Int
    public var tags: Int

    public init(hosts: Int, groups: Int, tags: Int) {
        self.hosts = hosts
        self.groups = groups
        self.tags = tags
    }

    /// Whether there is not a single host, group or tag.
    public var isEmpty: Bool { hosts == 0 && groups == 0 && tags == 0 }
}

/// Why a file cannot be imported. The description says so in a sentence for the user.
public enum ImportError: Error, Hashable, CustomStringConvertible {
    /// The file is larger than `ExportFile.maximumByteCount`.
    case tooLarge
    /// The file is not JSON: it is no export, or a damaged or incomplete one, for example cut off.
    case unreadable
    /// The file is JSON, but not a Shello export.
    case notAnExport
    /// A newer version of Shello wrote the file, in a schema version this one does not know.
    case newerSchemaVersion(Int)
    /// A value is missing, has the wrong type or cannot be read, at `path` if the decoder knows where,
    /// such as `hosts[2].port`.
    case damaged(path: String?)
    /// The file reads, but these records break a rule, each said in a sentence.
    case invalidRecords([String])

    public var description: String {
        switch self {
        case .tooLarge:
            "The file is too large to be a Shello export."
        case .unreadable:
            "The file isn’t a Shello export, or it’s damaged or incomplete."
        case .notAnExport:
            "The file isn’t a Shello export."
        case .newerSchemaVersion:
            "The file comes from a newer version of Shello. Update Shello, then import the file again."
        case .damaged(let path?):
            "The file is damaged: the value at \(path) is missing or invalid."
        case .damaged(nil):
            "The file is damaged: a value is missing or invalid."
        case .invalidRecords(let problems):
            switch problems.count {
            case 0: "The file has a record Shello can’t import."
            case 1: problems[0]
            case 2: "\(problems[0]) There is 1 more problem."
            default: "\(problems[0]) There are \(problems.count - 1) more problems."
            }
        }
    }
}

extension DecodingError {
    /// Where in the file the error is, such as `hosts[2].port`, or nil if the decoder does not say.
    fileprivate var path: String? {
        let codingPath: [any CodingKey]
        switch self {
        case .keyNotFound(let key, let context): codingPath = context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            codingPath = context.codingPath
        @unknown default: return nil
        }
        guard !codingPath.isEmpty else { return nil }
        return codingPath.reduce(into: "") { path, key in
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }
}
