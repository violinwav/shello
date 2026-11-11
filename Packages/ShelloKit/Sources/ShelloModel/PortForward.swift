import Foundation

/// One of a host's port forwards (README section 4), which listens on this device's loopback while
/// the host's tab is connected, and carries each connection it accepts over the tab's connection:
/// to a destination the server reaches, for a local forward, or to the one each client asks for, for
/// a dynamic forward, a SOCKS5 server. A host's forwards are one of its fields, saved and exported
/// with it. Remote forwards come in their own kind.
public struct PortForward: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// What the user calls the forward, such as "Database"; empty for none.
    public var name: String
    /// The port it listens on, on 127.0.0.1 only (STACK section 7.1).
    public var localPort: UInt16
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
    }

    /// The ports a forward can listen on.
    public static let validPorts: ClosedRange<UInt16> = 1...65535

    public init(id: UUID = UUID(), name: String = "", localPort: UInt16, kind: Kind, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.kind = kind
        self.isEnabled = isEnabled
    }

    /// The destination of a local forward; nil for a dynamic one.
    public var destination: ForwardDestination? {
        if case .local(let destination) = kind { destination } else { nil }
    }

    /// Whether the forward is a dynamic one, a SOCKS5 server.
    public var isDynamic: Bool { kind == .dynamic }
}

/// Where a local forward's connections go: an address and port as the server reaches them, which
/// need not be reachable from the device, such as `db.internal:5432` or `localhost:8080` on the server.
public struct ForwardDestination: Hashable, Sendable {
    /// A hostname, an IPv4 address or an IPv6 address, which the server resolves.
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
    /// import follow: a destination that is a hostname, an IPv4 or an IPv6 address, ports from 1 to
    /// 65535, and no null character in the text, which the database stores but reads back cut off.
    /// Port 0 cannot be stored in the forward, so only its destination's port is checked.
    public var problems: [String] {
        var problems: [String] = []
        if localPort == 0 {
            problems.append("It listens on port 0, but a port is from 1 to 65535.")
        }
        if name.unicodeScalars.contains("\0") {
            problems.append("Its name has a null character, which Shello can’t store.")
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

    /// The local ports that more than one of `forwards` that are on listen on: only one of them
    /// could listen.
    public static func sharedPorts(_ forwards: [PortForward]) -> Set<UInt16> {
        var seen: Set<UInt16> = []
        var shared: Set<UInt16> = []
        for forward in forwards where forward.isEnabled {
            if !seen.insert(forward.localPort).inserted {
                shared.insert(forward.localPort)
            }
        }
        return shared
    }
}
