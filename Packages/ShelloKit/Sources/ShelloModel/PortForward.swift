import Foundation

/// One of a host's port forwards (README section 4), which listens on a port while the host's tab is
/// connected, and carries each connection it accepts over the tab's connection:
/// - a local forward listens on this device's loopback, and each connection goes to a destination
///   the server reaches;
/// - a dynamic forward listens on this device's loopback too, as a SOCKS5 server, through which each
///   client asks for the destination the server reaches;
/// - a remote forward has the server listen on a port of its own, and each connection the server
///   accepts comes back over the connection to a destination this device reaches.
///
/// A host's forwards are one of its fields, saved and exported with it.
public struct PortForward: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// What the user calls the forward, such as "Database"; empty for none.
    public var name: String
    /// The port it listens on: on 127.0.0.1 of this device for a local or dynamic forward (STACK
    /// section 7.1), on the server for a remote one, as the port in OpenSSH's
    /// `LocalForward [bind_address:]port` and `RemoteForward [bind_address:]port`.
    public var port: UInt16
    public var kind: Kind
    /// Whether the forward listens when the tab connects. One that is off is kept, and does nothing.
    public var isEnabled: Bool

    /// What a forward does with each connection it accepts.
    public enum Kind: Hashable, Sendable {
        /// A local forward, as OpenSSH's `LocalForward` or `ssh -L`: each connection goes to
        /// `destination`, as the server reaches it.
        case local(destination: ForwardDestination)
        /// A dynamic forward, as OpenSSH's `DynamicForward` or `ssh -D`: a SOCKS5 server, through which
        /// each client asks for its own destination, which the server reaches.
        case dynamic
        /// A remote forward, as OpenSSH's `RemoteForward` or `ssh -R`: the server listens on its port,
        /// on `bindAddress`, and each connection it accepts goes to `destination`, as this device
        /// reaches it. `bindAddress` is empty for the server's loopback, OpenSSH's default, and `*`
        /// for all of the server's addresses; the server's `GatewayPorts` decides whether it honours
        /// anything but its loopback.
        case remote(bindAddress: String, destination: ForwardDestination)
    }

    /// The ports a forward can listen on.
    public static let validPorts: ClosedRange<UInt16> = 1...65535

    /// The bind address that stands for all of the server's addresses, as in OpenSSH's
    /// `RemoteForward *:8080`.
    public static let allAddresses = "*"

    public init(id: UUID = UUID(), name: String = "", port: UInt16, kind: Kind, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.port = port
        self.kind = kind
        self.isEnabled = isEnabled
    }

    /// Where the forward's connections go: the server's destination for a local forward, this
    /// device's for a remote one; nil for a dynamic one, whose clients each say where to go.
    public var destination: ForwardDestination? {
        switch kind {
        case .local(let destination), .remote(_, let destination): destination
        case .dynamic: nil
        }
    }

    /// Whether the forward is a dynamic one, a SOCKS5 server.
    public var isDynamic: Bool { kind == .dynamic }

    /// Whether the forward is a remote one, which the server listens for.
    public var isRemote: Bool {
        if case .remote = kind { true } else { false }
    }

    /// The address a remote forward has the server listen on, as typed: empty for the server's
    /// loopback; nil for a local or dynamic forward.
    public var bindAddress: String? {
        if case .remote(let bindAddress, _) = kind { bindAddress } else { nil }
    }
}

/// Where a forward's connections go: an address and port as the server reaches them, for a local
/// forward, which need not be reachable from the device, such as `db.internal:5432` or
/// `localhost:8080` on the server; or as this device reaches them, for a remote forward.
public struct ForwardDestination: Hashable, Sendable {
    /// A hostname, an IPv4 address or an IPv6 address, which the server resolves for a local forward,
    /// and this device for a remote one.
    public var address: String
    public var port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

extension ForwardDestination: CustomStringConvertible {
    /// The address and port as people write them: `db.internal:5432`, or `[fd00::5]:5432` for an
    /// IPv6 address, whose colons would run into the port's.
    public var description: String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}

extension PortForward {
    /// What is wrong with the forward, in a sentence each, by the rules that the host editor and an
    /// import follow: a destination that is a hostname, an IPv4 or an IPv6 address, a remote
    /// forward's bind address that is empty, `*`, or one of those, ports from 1 to 65535, and no null
    /// character in the text, which the database stores but reads back cut off. Port 0 cannot be
    /// stored in the forward, so only its destination's port is checked.
    public var problems: [String] {
        var problems: [String] = []
        if port == 0 {
            problems.append("It listens on port 0, but a port is from 1 to 65535.")
        }
        if name.unicodeScalars.contains("\0") {
            problems.append("Its name has a null character, which Shello can’t store.")
        }
        if let bindAddress, !Self.isBindAddress(bindAddress) {
            problems.append("Its bind address isn’t empty, *, a hostname, an IPv4 address or an IPv6 address.")
        }
        if let destination {
            if destination.address.unicodeScalars.contains("\0") || AddressKind(of: destination.address) == nil {
                problems.append("Its destination isn’t a hostname, an IPv4 address or an IPv6 address.")
            }
            if destination.port == 0 {
                problems.append("Its destination’s port is 0, but a port is from 1 to 65535.")
            }
        }
        return problems
    }

    /// Whether `text` can be a remote forward's bind address: empty for the server's loopback, `*`
    /// for all of its addresses, or a hostname, an IPv4 address or an IPv6 address.
    public static func isBindAddress(_ text: String) -> Bool {
        text.isEmpty || text == allAddresses
            || (!text.unicodeScalars.contains("\0") && AddressKind(of: text) != nil)
    }

    /// The ports that more than one of `forwards` that are on listen on, on one side: this device's
    /// loopback, which local and dynamic forwards share, or the server, for remote forwards. Only one
    /// of them could listen. A local forward and a remote one on the same port listen on different
    /// machines, and are no problem.
    public static func sharedPorts(_ forwards: [PortForward], onServer: Bool = false) -> Set<UInt16> {
        var seen: Set<UInt16> = []
        var shared: Set<UInt16> = []
        for forward in forwards where forward.isEnabled && forward.isRemote == onServer {
            if !seen.insert(forward.port).inserted {
                shared.insert(forward.port)
            }
        }
        return shared
    }
}

extension ForwardDestination {
    /// Whether the destination probably lies on the local network, as `Server.isOnLocalNetwork`
    /// guesses from its address: a remote forward's connection to it then needs iOS's Local Network
    /// access (README section 3).
    public var isOnLocalNetwork: Bool {
        Server(address: address, port: port).isOnLocalNetwork
    }
}
