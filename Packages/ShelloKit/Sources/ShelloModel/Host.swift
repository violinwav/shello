import Foundation

/// A saved entry that holds everything needed to reach one server as one user (README section 3).
///
/// A host never holds a secret: it refers to its SSH key by identifier, and passwords live in
/// the Keychain (README section 13).
public struct Host: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// A hostname, an IPv4 address or an IPv6 address.
    public var address: String
    public var port: UInt16
    public var `protocol`: HostProtocol
    public var username: String
    public var authMethod: AuthMethod
    /// The SSH key to sign in with when `authMethod` is `.sshKey`. The key itself stays in the
    /// Keychain or the Secure Enclave, and may not exist on this device (README section 15).
    public var sshKeyID: UUID?
    /// The one group the host belongs to, if any. Groups do not nest.
    public var groupID: HostGroup.ID?
    public var tagIDs: Set<Tag.ID>
    public var notes: String
    /// Run once the connection is authenticated. Empty for none.
    public var startupCommand: String
    /// Whether each connection attaches the host's tmux session once its startup command is typed,
    /// and starts it if it is not running, so that a reconnect reattaches it (README section 8):
    /// auto-attach.
    public var tmuxAutoAttach: Bool
    /// The tmux session auto-attach attaches, a `TmuxSessionName`.
    public var tmuxSessionName: String
    /// The `TERM` value Shello sends to the server.
    public var terminalType: String
    /// How often Shello checks that the connection is alive. A tab shows the round trip as its
    /// latency (README section 4).
    public var keepaliveInterval: Duration
    /// How long Shello waits for the server before it gives up connecting.
    public var connectTimeout: Duration
    public var isFavorite: Bool
    /// When Shello last connected to the host, or nil if it never has.
    public var lastConnectedAt: Date?

    /// The ports a host can use. Port 0 is reserved.
    public static let validPorts: ClosedRange<UInt16> = 1...65535
    /// The `TERM` value for new hosts.
    public static let defaultTerminalType = "xterm-256color"
    /// The keepalive interval for new hosts: a starting value, to confirm during the MVP.
    public static let defaultKeepaliveInterval = Duration.seconds(30)
    /// The connect timeout for new hosts: a starting value, to confirm during the MVP.
    public static let defaultConnectTimeout = Duration.seconds(15)
    /// The tmux session new hosts attach once auto-attach is on, as in `tmux new -A -s main`.
    public static let defaultTmuxSessionName = "main"

    /// Creates a host. Without a port, the host uses its protocol's default port.
    public init(
        id: UUID = UUID(),
        name: String,
        address: String,
        port: UInt16? = nil,
        protocol: HostProtocol = .ssh,
        username: String,
        authMethod: AuthMethod = .sshKey,
        sshKeyID: UUID? = nil,
        groupID: HostGroup.ID? = nil,
        tagIDs: Set<Tag.ID> = [],
        notes: String = "",
        startupCommand: String = "",
        tmuxAutoAttach: Bool = false,
        tmuxSessionName: String = Host.defaultTmuxSessionName,
        terminalType: String = Host.defaultTerminalType,
        keepaliveInterval: Duration = Host.defaultKeepaliveInterval,
        connectTimeout: Duration = Host.defaultConnectTimeout,
        isFavorite: Bool = false,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port ?? `protocol`.defaultPort
        self.protocol = `protocol`
        self.username = username
        self.authMethod = authMethod
        self.sshKeyID = sshKeyID
        self.groupID = groupID
        self.tagIDs = tagIDs
        self.notes = notes
        self.startupCommand = startupCommand
        self.tmuxAutoAttach = tmuxAutoAttach
        self.tmuxSessionName = tmuxSessionName
        self.terminalType = terminalType
        self.keepaliveInterval = keepaliveInterval
        self.connectTimeout = connectTimeout
        self.isFavorite = isFavorite
        self.lastConnectedAt = lastConnectedAt
    }
}

/// How Shello talks to a host's server, which decides the kind of tab it opens.
public enum HostProtocol: Hashable, Sendable, CaseIterable {
    case ssh
    case mosh
    case vnc

    /// Mosh starts over SSH, so its port is the SSH port.
    public var defaultPort: UInt16 {
        switch self {
        case .ssh, .mosh: 22
        case .vnc: 5900
        }
    }
}

/// How Shello signs in to a host's server.
public enum AuthMethod: Hashable, Sendable, CaseIterable {
    case sshKey
    case password
    case keyboardInteractive
}
