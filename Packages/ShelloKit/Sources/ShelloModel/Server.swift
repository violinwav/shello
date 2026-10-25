/// The remote computer a host points at, identified by its address and port (GLOSSARY). Several hosts
/// can point at the same server, for example as different users, and trust in a host key belongs to
/// the server, so it covers all of them (README section 3).
public struct Server: Hashable, Sendable {
    /// The host's address, in lowercase: host names and IPv6 addresses ignore case, so `NAS.lan` and
    /// `nas.lan` are the same server.
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address.lowercased()
        self.port = port
    }
}

extension Host {
    /// The server the host points at.
    public var server: Server {
        Server(address: address, port: port)
    }
}

extension Server: CustomStringConvertible {
    /// The address and port as people write them: `nas.lan:22`, or `[fe80::1]:22` for an IPv6
    /// address, whose colons would run into the port's.
    public var description: String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }
}
