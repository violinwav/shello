// SOCKS5 as a dynamic forward serves it (README section 4, STACK sections 2 and 7.1): written in-house,
// fuzzed (Fuzz/SOCKS5), and with the standard library only, so that the fuzz target builds on Linux.

/// SOCKS5 (RFC 1928) as Shello's dynamic forwards serve it, as OpenSSH's `DynamicForward` does: no
/// authentication, and CONNECT only, to an IPv4 or IPv6 address or a domain name. A domain name goes
/// to the server as it is, unresolved, so that the server resolves it: a name only the server's
/// network knows works, and the device's resolver never sees it.
///
/// Anything else gets SOCKS5's own answer: a client that offers no way in without authentication is
/// told that none of its methods is acceptable, and a request to bind a port or to relay UDP, or for
/// an address type SOCKS5 does not know, gets the reply for it.
public enum SOCKS5 {
    /// The protocol version, the first byte of every greeting, request and reply.
    public static let version: UInt8 = 5

    /// The authentication method "no authentication required", the only one Shello takes.
    static let noAuthentication: UInt8 = 0x00
    /// The method selection's "no acceptable methods".
    static let noAcceptableMethods: UInt8 = 0xFF

    /// The command CONNECT, the only one Shello serves. BIND (2) and UDP ASSOCIATE (3) get
    /// `Reply.commandNotSupported`.
    static let connectCommand: UInt8 = 1

    /// The address types of a request.
    enum AddressType {
        static let ipv4: UInt8 = 1
        static let domainName: UInt8 = 3
        static let ipv6: UInt8 = 4
    }

    /// The method selection message that answers a greeting: `noAuthentication`, or
    /// `noAcceptableMethods`, after which the client closes the connection.
    static func methodSelection(_ method: UInt8) -> [UInt8] {
        [version, method]
    }

    /// The replies to a request (RFC 1928 section 6), by their code.
    public enum Reply: UInt8, CaseIterable, Sendable {
        /// The connection to the destination is open; what follows is the destination's.
        case succeeded = 0x00
        /// General SOCKS server failure: anything without a reply of its own.
        case generalFailure = 0x01
        /// Connection not allowed by ruleset: the server does not forward TCP.
        case connectionNotAllowed = 0x02
        case networkUnreachable = 0x03
        /// The server cannot reach the host, or cannot resolve its name.
        case hostUnreachable = 0x04
        case connectionRefused = 0x05
        case ttlExpired = 0x06
        /// A command other than CONNECT.
        case commandNotSupported = 0x07
        /// An address type other than IPv4, IPv6 and a domain name.
        case addressTypeNotSupported = 0x08

        /// The reply's bytes. The bound address is 0.0.0.0, port 0, as OpenSSH's: the address the
        /// server connects from is the server's to know, and clients do not use it for CONNECT.
        public var bytes: [UInt8] {
            [SOCKS5.version, rawValue, 0x00, AddressType.ipv4, 0, 0, 0, 0, 0, 0]
        }
    }

    /// Where a client asks to connect, as the server reaches it.
    public struct Destination: Hashable, Sendable {
        public var host: Host
        public var port: UInt16

        public init(host: Host, port: UInt16) {
            self.host = host
            self.port = port
        }

        public enum Host: Hashable, Sendable {
            /// An IPv4 address, its 4 bytes.
            case ipv4([UInt8])
            /// An IPv6 address, its 16 bytes.
            case ipv6([UInt8])
            /// A domain name, printable ASCII, which the server resolves.
            case domainName(String)
        }

        /// The address as the server is asked to connect to it: an IPv4 address in dotted decimal,
        /// an IPv6 address as RFC 5952 writes it, or the domain name as the client gave it.
        public var address: String {
            switch host {
            case .ipv4(let bytes): SOCKS5.ipv4Text(bytes)
            case .ipv6(let bytes): SOCKS5.ipv6Text(bytes)
            case .domainName(let name): name
            }
        }
    }

    /// Why a handshake ended without a destination.
    public enum Failure: Hashable, Sendable {
        /// The client does not speak SOCKS5: its first byte is not 5. It may be SOCKS4, which Shello
        /// does not serve. It gets no answer, as it would not read one.
        case notSOCKS5
        /// The client offered no way in without authentication.
        case noAcceptableMethod
        /// A command other than CONNECT, such as BIND or UDP ASSOCIATE.
        case unsupportedCommand(UInt8)
        /// An address type other than IPv4, IPv6 and a domain name.
        case unsupportedAddressType(UInt8)
        /// A domain name that is empty, or has bytes other than printable ASCII, such as a null
        /// byte, which would cut the name short on its way to the server.
        case invalidDomainName
    }

    /// The dotted decimal form of an IPv4 address's 4 bytes.
    static func ipv4Text(_ bytes: [UInt8]) -> String {
        bytes.map(String.init).joined(separator: ".")
    }

    /// The text form of an IPv6 address's 16 bytes, as RFC 5952 section 4 writes it: lowercase hex
    /// without leading zeros, and the longest run of two or more zero groups, the first of runs
    /// equally long, written as `::`.
    static func ipv6Text(_ bytes: [UInt8]) -> String {
        let groups = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        var longest: Range<Int>?
        var start: Int?
        for index in 0...groups.count {
            if index < groups.count, groups[index] == 0 {
                if start == nil { start = index }
            } else if let runStart = start {
                let run = runStart..<index
                if run.count >= 2, run.count > longest?.count ?? 0 { longest = run }
                start = nil
            }
        }
        let hex = groups.map { String($0, radix: 16) }
        guard let longest else { return hex.joined(separator: ":") }
        let head = hex[..<longest.lowerBound].joined(separator: ":")
        let tail = hex[longest.upperBound...].joined(separator: ":")
        return head + "::" + tail
    }
}

/// The server's side of a SOCKS5 handshake, read from the client's bytes as they arrive, in pieces
/// of any size: the greeting, which Shello answers by choosing no authentication, then the request.
///
/// `receive(_:)` says what to send the client and how the handshake stands. Once the request is
/// read, the caller connects to its destination and sends the client `SOCKS5.Reply.succeeded`, or
/// the reply for why it could not; what the client sent after its request goes to the destination.
/// After a failure, the caller sends what `receive(_:)` said, if anything, and closes the
/// connection. Call it until the outcome is no longer pending; bytes given after that are ignored.
public struct SOCKS5Handshake: Sendable {
    /// What to send the client now, and how the handshake stands.
    public struct Step: Equatable, Sendable {
        /// The bytes to send the client: the method selection, or a failure's reply.
        public var send: [UInt8]
        public var outcome: Outcome
    }

    public enum Outcome: Equatable, Sendable {
        /// The handshake waits for more of the client's bytes.
        case pending
        /// The client asks to connect to `destination`. `rest` is what it sent after its request,
        /// for the destination.
        case connect(SOCKS5.Destination, rest: [UInt8])
        /// The handshake failed: the caller sends what the step says, then closes the connection.
        case failed(SOCKS5.Failure)
    }

    private enum Phase {
        case greeting
        case request
        case done
    }

    private var phase = Phase.greeting
    /// The client's bytes not read yet.
    private var buffer: [UInt8] = []

    public init() {}

    /// Whether the handshake has an outcome, and reads no more.
    public var isDone: Bool { phase == .done }

    /// Reads `bytes`, the client's next ones, after those given before.
    public mutating func receive(_ bytes: [UInt8]) -> Step {
        guard phase != .done else { return Step(send: [], outcome: .pending) }
        buffer += bytes
        var send: [UInt8] = []
        if phase == .greeting {
            switch readGreeting() {
            case .incomplete:
                return Step(send: [], outcome: .pending)
            case .failed(let failure, let reply):
                phase = .done
                return Step(send: reply, outcome: .failed(failure))
            case .read(let selection):
                send = selection
                phase = .request
            }
        }
        switch readRequest() {
        case .incomplete:
            return Step(send: send, outcome: .pending)
        case .failed(let failure, let reply):
            phase = .done
            return Step(send: send + reply, outcome: .failed(failure))
        case .read(let destination):
            phase = .done
            let rest = buffer
            buffer = []
            return Step(send: send, outcome: .connect(destination, rest: rest))
        }
    }

    private enum Read<Value> {
        case incomplete
        case read(Value)
        /// The handshake fails, after `reply` is sent.
        case failed(SOCKS5.Failure, reply: [UInt8])
    }

    /// The greeting: the version, then the number of methods and the methods. Answered with no
    /// authentication when the client offers it.
    private mutating func readGreeting() -> Read<[UInt8]> {
        guard let first = buffer.first else { return .incomplete }
        guard first == SOCKS5.version else { return .failed(.notSOCKS5, reply: []) }
        guard buffer.count >= 2 else { return .incomplete }
        let count = Int(buffer[1])
        guard buffer.count >= 2 + count else { return .incomplete }
        let methods = buffer[2..<(2 + count)]
        buffer.removeFirst(2 + count)
        guard methods.contains(SOCKS5.noAuthentication) else {
            return .failed(.noAcceptableMethod, reply: SOCKS5.methodSelection(SOCKS5.noAcceptableMethods))
        }
        return .read(SOCKS5.methodSelection(SOCKS5.noAuthentication))
    }

    /// The request: the version, the command, a reserved byte, the address type, the address and
    /// the port. A command other than CONNECT is refused once the whole request is read, so that the
    /// reply is not lost to a connection closed on bytes it has not read. An address type SOCKS5
    /// does not know is refused at once: how long its address is, nobody knows.
    private mutating func readRequest() -> Read<SOCKS5.Destination> {
        guard buffer.count >= 4 else {
            if let first = buffer.first, first != SOCKS5.version {
                return .failed(.notSOCKS5, reply: SOCKS5.Reply.generalFailure.bytes)
            }
            return .incomplete
        }
        guard buffer[0] == SOCKS5.version else {
            return .failed(.notSOCKS5, reply: SOCKS5.Reply.generalFailure.bytes)
        }
        let command = buffer[1]
        let addressType = buffer[3]
        let addressLength: Int
        switch addressType {
        case SOCKS5.AddressType.ipv4:
            addressLength = 4
        case SOCKS5.AddressType.ipv6:
            addressLength = 16
        case SOCKS5.AddressType.domainName:
            guard buffer.count >= 5 else { return .incomplete }
            addressLength = 1 + Int(buffer[4])
        default:
            return .failed(.unsupportedAddressType(addressType), reply: SOCKS5.Reply.addressTypeNotSupported.bytes)
        }
        let length = 4 + addressLength + 2
        guard buffer.count >= length else { return .incomplete }
        let address = Array(buffer[4..<(4 + addressLength)])
        let port = UInt16(buffer[length - 2]) << 8 | UInt16(buffer[length - 1])
        buffer.removeFirst(length)
        guard command == SOCKS5.connectCommand else {
            return .failed(.unsupportedCommand(command), reply: SOCKS5.Reply.commandNotSupported.bytes)
        }
        let host: SOCKS5.Destination.Host
        switch addressType {
        case SOCKS5.AddressType.ipv4:
            host = .ipv4(address)
        case SOCKS5.AddressType.ipv6:
            host = .ipv6(address)
        default:
            let name = address.dropFirst()
            guard !name.isEmpty, name.allSatisfy({ (0x21...0x7E).contains($0) }) else {
                return .failed(.invalidDomainName, reply: SOCKS5.Reply.generalFailure.bytes)
            }
            host = .domainName(String(decoding: name, as: UTF8.self))
        }
        return .read(SOCKS5.Destination(host: host, port: port))
    }
}
