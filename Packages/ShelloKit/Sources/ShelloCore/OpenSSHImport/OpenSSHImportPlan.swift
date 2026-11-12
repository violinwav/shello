import Foundation
import ShelloModel

/// What an import from an OpenSSH config file and a known_hosts file would do (README section 3),
/// for the user to see before anything is stored: the hosts it adds, with their jump hosts and
/// forwards, the hosts Shello has already, the host keys it trusts, the trusted keys it keeps, and
/// every line it does not import, with its number and why. Nothing is dropped silently.
///
/// `OpenSSHImport.plan(…)` makes it; `HostImportRepository.importHosts(_:trusting:)` stores it.
public struct OpenSSHImportPlan: Hashable, Sendable {
    /// A host the import adds.
    public struct NewHost: Identifiable, Hashable, Sendable {
        public var id: Host.ID { host.id }
        /// The host as it will be stored.
        public let host: Host
        /// Where it comes from in the config file.
        public let origin: Origin
        /// Its jump hosts, in order, and where each is.
        public let jumpHosts: [JumpHost]
        /// The SSH key it signs in with.
        public let sshKey: SSHKeyChoice
        /// The line that names it: its `Host` line, or for a jump host the `ProxyJump` that names it.
        public var line: Int {
            switch origin {
            case .alias(let line), .jumpHost(_, let line): line
            }
        }
    }

    /// Where a new host comes from in the config file.
    public enum Origin: Hashable, Sendable {
        /// A name on the `Host` line `line`.
        case alias(line: Int)
        /// A jump host that `ProxyJump` on `line` names, for the host `of`, which is no name on a
        /// `Host` line and no host in Shello.
        case jumpHost(of: String, line: Int)
    }

    /// One of a new host's jump hosts.
    public struct JumpHost: Hashable, Sendable {
        public let name: String
        /// Whether it is a host Shello has already, rather than one the import adds.
        public let isSaved: Bool
    }

    /// The SSH key a new host signs in with.
    public enum SSHKeyChoice: Hashable, Sendable {
        /// The SSH key of this device named after the host's `IdentityFile`, as importing a key from
        /// Files names it.
        case key(id: UUID, name: String)
        /// None yet: the user chooses one in the host editor. `fileToImport` is the name of the
        /// host's `IdentityFile`, which no key of this device has, to import first.
        case toChoose(fileToImport: String?)
    }

    /// A host of the config file that Shello has already: the same address, port, user and jump
    /// hosts. It is not added again, and the host in Shello stays as it is.
    public struct ExistingHost: Hashable, Sendable {
        public let name: String
        /// Its `Host` line.
        public let line: Int
        /// The host in Shello.
        public let saved: Host
    }

    /// A host key the import trusts for a server that has none.
    public struct NewKey: Hashable, Sendable {
        public let server: Server
        public let key: HostKey
        /// Its line in the known_hosts file.
        public let line: Int
    }

    /// A host key of the known_hosts file for a server that Shello trusts a key for already.
    public struct KnownKey: Hashable, Sendable {
        public let server: Server
        /// The file's key.
        public let key: HostKey
        public let line: Int
        /// The key Shello trusts for the server, which the import keeps. When it is `key`, the line
        /// changes nothing; when it is another, the line is a conflict: replacing a trusted key takes
        /// the explicit action of the changed-key sheet, and Face ID (README section 3).
        public let trusted: HostKey

        public init(server: Server, key: HostKey, line: Int, trusted: HostKey) {
            self.server = server
            self.key = key
            self.line = line
            self.trusted = trusted
        }

        public var isConflict: Bool { trusted != key }
    }

    /// A line of one of the files that the import leaves out, or a part of one, and why.
    public struct NotImported: Identifiable, Hashable, Sendable {
        public var id: String { "\(file)-\(line)-\(text)-\(reason)" }
        public let file: File
        /// The line's number, from 1.
        public let line: Int
        /// The line, or the part of it that is left out.
        public let text: String
        /// Why, in a sentence or two.
        public let reason: String
    }

    /// One of the two files an import reads.
    public enum File: Hashable, Sendable, Comparable {
        case config
        case knownHosts
    }

    public internal(set) var hosts: [NewHost] = []
    public internal(set) var existingHosts: [ExistingHost] = []
    public internal(set) var keys: [NewKey] = []
    /// The known_hosts file's keys for servers that have a trusted key already, the conflicts among
    /// them included.
    public internal(set) var knownKeys: [KnownKey] = []
    /// What the import leaves out, by file and line.
    public internal(set) var notImported: [NotImported] = []

    public init() {}

    /// The keys of `knownKeys` that differ from the trusted ones, which the import keeps.
    public var conflicts: [KnownKey] { knownKeys.filter(\.isConflict) }

    /// Whether the import would add nothing: no host and no host key.
    public var addsNothing: Bool { hosts.isEmpty && keys.isEmpty }

    /// The hosts to add, as they will be stored.
    public var hostsToStore: [Host] { hosts.map(\.host) }

    /// The host keys to trust, by server.
    public var keysToTrust: [Server: HostKey] {
        Dictionary(keys.map { ($0.server, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    /// The identity files that new hosts name and that no SSH key of this device is named after, each
    /// with the hosts that name it: the keys to import, in the order the hosts come.
    public var keyFilesToImport: [(file: String, hosts: [String])] {
        var files: [(file: String, hosts: [String])] = []
        for host in hosts {
            guard case .toChoose(let file?) = host.sshKey else { continue }
            if let index = files.firstIndex(where: { $0.file == file }) {
                files[index].hosts.append(host.host.name)
            } else {
                files.append((file, [host.host.name]))
            }
        }
        return files
    }
}
