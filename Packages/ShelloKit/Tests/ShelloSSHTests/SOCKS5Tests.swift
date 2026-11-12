import Foundation
import Testing

@testable import ShelloSSH

/// SOCKS5 as a dynamic forward serves it (README section 4): the greeting, answered with no
/// authentication or with "no acceptable methods"; CONNECT to an IPv4 or IPv6 address and to a
/// domain name, which stays unresolved; every reply, and the reply for each thing Shello does not
/// serve; the bytes in pieces of any size; and the reply for each way the server can fail to open the
/// tunnel. `randomBytesNeverTrap` is a short, seeded version of the fuzz target Fuzz/SOCKS5.
struct SOCKS5Tests {
    // MARK: - Replies

    /// Every reply of RFC 1928 section 6: the version, the code, a reserved zero, and the bound
    /// address 0.0.0.0, port 0.
    @Test(arguments: SOCKS5.Reply.allCases)
    func everyReplyIsTheVersionItsCodeAndNoBoundAddress(_ reply: SOCKS5.Reply) {
        #expect(reply.bytes == [5, reply.rawValue, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    @Test func replyCodesAreRFC1928s() {
        #expect(SOCKS5.Reply.allCases.map(\.rawValue) == Array(0...8))
        #expect(SOCKS5.Reply.succeeded.rawValue == 0x00)
        #expect(SOCKS5.Reply.generalFailure.rawValue == 0x01)
        #expect(SOCKS5.Reply.connectionNotAllowed.rawValue == 0x02)
        #expect(SOCKS5.Reply.networkUnreachable.rawValue == 0x03)
        #expect(SOCKS5.Reply.hostUnreachable.rawValue == 0x04)
        #expect(SOCKS5.Reply.connectionRefused.rawValue == 0x05)
        #expect(SOCKS5.Reply.ttlExpired.rawValue == 0x06)
        #expect(SOCKS5.Reply.commandNotSupported.rawValue == 0x07)
        #expect(SOCKS5.Reply.addressTypeNotSupported.rawValue == 0x08)
    }

    // MARK: - The greeting

    /// A client that offers no authentication, among others, gets it.
    @Test(arguments: [[0x00], [0x02, 0x00], [0x01, 0x02, 0x00, 0x80]] as [[UInt8]])
    func greetingWithNoAuthenticationIsAnsweredWithIt(_ methods: [UInt8]) {
        var handshake = SOCKS5Handshake()

        let step = handshake.receive([5, UInt8(methods.count)] + methods)

        #expect(step == SOCKS5Handshake.Step(send: [5, 0x00], outcome: .pending))
        #expect(!handshake.isDone)
    }

    /// A client that only offers to authenticate, or offers nothing, is told that none of its
    /// methods is acceptable, and the handshake ends.
    @Test(arguments: [[0x02], [0x01, 0x02], []] as [[UInt8]])
    func greetingWithoutNoAuthenticationIsRefused(_ methods: [UInt8]) {
        var handshake = SOCKS5Handshake()

        let step = handshake.receive([5, UInt8(methods.count)] + methods)

        #expect(step == SOCKS5Handshake.Step(send: [5, 0xFF], outcome: .failed(.noAcceptableMethod)))
        #expect(handshake.isDone)
    }

    /// A SOCKS4 client, or anything else that is not SOCKS5, gets no answer: it would not read one.
    @Test(arguments: [[4, 1, 0, 80, 127, 0, 0, 1, 0], Array("GET / HTTP/1.1\r\n".utf8)] as [[UInt8]])
    func clientThatIsNotSOCKS5GetsNoAnswer(_ bytes: [UInt8]) {
        var handshake = SOCKS5Handshake()

        #expect(handshake.receive(bytes) == SOCKS5Handshake.Step(send: [], outcome: .failed(.notSOCKS5)))
    }

    // MARK: - CONNECT

    @Test func connectToAnIPv4Address() {
        let step = Self.connect([0x01, 192, 168, 1, 20], port: 5432)

        let destination = SOCKS5.Destination(host: .ipv4([192, 168, 1, 20]), port: 5432)
        #expect(step.outcome == .connect(destination, rest: []))
        #expect(destination.address == "192.168.1.20")
    }

    /// IPv6 addresses go to the server as RFC 5952 writes them.
    @Test(
        arguments: [
            ([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], "::1"),
            ([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "::"),
            ([0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01], "2001:db8::1"),
            ([0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1], "2001:db8::1:0:0:1"),
            ([0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1], "2001:db8:0:1:1:1:1:1"),
            ([0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5], "fd00::5"),
            ([0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0x0A, 0xBC, 0, 0, 0, 0, 0x12, 0x34], "fe80::abc:0:0:1234"),
            ([0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0, 8], "1:2:3:4:5:6:7:8"),
            ([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], "0:0:1::1"),
        ] as [([UInt8], String)])
    func connectToAnIPv6Address(_ bytes: [UInt8], _ text: String) {
        let step = Self.connect([0x04] + bytes, port: 443)

        let destination = SOCKS5.Destination(host: .ipv6(bytes), port: 443)
        #expect(step.outcome == .connect(destination, rest: []))
        #expect(destination.address == text)
    }

    /// A domain name stays unresolved: the server resolves it, as OpenSSH's dynamic forwards do.
    @Test func connectToADomainNameKeepsItUnresolved() {
        let name = Array("db.internal".utf8)

        let step = Self.connect([0x03, UInt8(name.count)] + name, port: 5432)

        #expect(step.outcome == .connect(SOCKS5.Destination(host: .domainName("db.internal"), port: 5432), rest: []))
    }

    /// Port 65535 and port 0 are read as the two bytes say; the server says whether it connects.
    @Test(arguments: [0, 1, 80, 8080, 65535] as [UInt16])
    func portIsReadInNetworkOrder(_ port: UInt16) {
        let step = Self.connect([0x01, 10, 0, 0, 1], port: port)

        guard case .connect(let destination, _) = step.outcome else {
            Issue.record("\(step.outcome) is no connect")
            return
        }
        #expect(destination.port == port)
    }

    /// A client that sends its request, and its first bytes for the destination, without waiting
    /// for the method selection: the bytes after the request go to the destination.
    @Test func bytesAfterTheRequestAreForTheDestination() {
        var handshake = SOCKS5Handshake()
        let payload = Array("SSH-2.0-client\r\n".utf8)

        let step = handshake.receive([5, 1, 0] + Self.request([0x01, 127, 0, 0, 1], port: 22) + payload)

        #expect(step.send == [5, 0x00])
        #expect(
            step.outcome == .connect(SOCKS5.Destination(host: .ipv4([127, 0, 0, 1]), port: 22), rest: payload))
        #expect(handshake.isDone)
    }

    /// The bytes may arrive one at a time: the outcome is the same.
    @Test func bytesArrivingOneAtATimeGiveTheSameOutcome() {
        let name = Array("localhost".utf8)
        let bytes = [5, 2, 0x02, 0x00] + Self.request([0x03, UInt8(name.count)] + name, port: 2222)
        var handshake = SOCKS5Handshake()
        var sent: [UInt8] = []
        var outcome = SOCKS5Handshake.Outcome.pending

        for byte in bytes {
            #expect(outcome == .pending)
            let step = handshake.receive([byte])
            sent += step.send
            outcome = step.outcome
        }

        #expect(sent == [5, 0x00])
        #expect(outcome == .connect(SOCKS5.Destination(host: .domainName("localhost"), port: 2222), rest: []))
    }

    /// Once the handshake has its outcome, what follows is not read.
    @Test func bytesAfterTheOutcomeAreIgnored() {
        var handshake = SOCKS5Handshake()
        _ = handshake.receive([4, 1])

        #expect(handshake.receive([5, 1, 0]) == SOCKS5Handshake.Step(send: [], outcome: .pending))
    }

    // MARK: - What Shello does not serve

    /// BIND and UDP ASSOCIATE, and commands SOCKS5 does not have, get "command not supported", once
    /// the whole request is read.
    @Test(arguments: [0x02, 0x03, 0x00, 0x7F] as [UInt8])
    func commandOtherThanConnectIsNotSupported(_ command: UInt8) {
        var handshake = SOCKS5Handshake()
        _ = handshake.receive([5, 1, 0])
        let request = [5, command, 0] + [0x01, 10, 0, 0, 1, 0x1F, 0x90]

        #expect(handshake.receive(Array(request.dropLast())).outcome == .pending)
        let step = handshake.receive([request.last!])

        #expect(
            step
                == SOCKS5Handshake.Step(
                    send: [5, 0x07, 0, 1, 0, 0, 0, 0, 0, 0], outcome: .failed(.unsupportedCommand(command))))
    }

    /// An address type SOCKS5 does not know gets "address type not supported" at once: how long its
    /// address is, nobody can tell.
    @Test(arguments: [0x00, 0x02, 0x05, 0xFF] as [UInt8])
    func unknownAddressTypeIsNotSupported(_ addressType: UInt8) {
        var handshake = SOCKS5Handshake()
        _ = handshake.receive([5, 1, 0])

        let step = handshake.receive([5, 1, 0, addressType])

        #expect(
            step
                == SOCKS5Handshake.Step(
                    send: [5, 0x08, 0, 1, 0, 0, 0, 0, 0, 0], outcome: .failed(.unsupportedAddressType(addressType))))
    }

    /// A name that is empty, or has a byte that is no printable ASCII, such as a null byte that would
    /// cut it short on its way to the server, gets a general failure.
    @Test(arguments: ["", "db\0.internal", "db internal", "zürich.example", "tab\there"])
    func invalidDomainNameIsAGeneralFailure(_ name: String) {
        let bytes = Array(name.utf8)

        let step = Self.connect([0x03, UInt8(bytes.count)] + bytes, port: 80)

        #expect(step.send == [5, 0x01, 0, 1, 0, 0, 0, 0, 0, 0])
        #expect(step.outcome == .failed(.invalidDomainName))
    }

    /// A request that is not SOCKS5's, after a SOCKS5 greeting, gets a general failure.
    @Test func requestOfAnotherVersionIsAGeneralFailure() {
        var handshake = SOCKS5Handshake()
        _ = handshake.receive([5, 1, 0])

        let step = handshake.receive([4, 1, 0, 1])

        #expect(step == SOCKS5Handshake.Step(send: [5, 0x01, 0, 1, 0, 0, 0, 0, 0, 0], outcome: .failed(.notSOCKS5)))
    }

    // MARK: - When the server does not open the tunnel

    /// The server's reason for not opening the tunnel (RFC 4254 section 5.1), as libssh words it,
    /// becomes the SOCKS5 reply for it; anything else, such as a connection that ended, a general
    /// failure.
    @Test(arguments: [
        ("Channel opening failure: channel 3 error (1) open failed", SOCKS5.Reply.connectionNotAllowed),
        ("Channel opening failure: channel 3 error (2) Connection refused", .connectionRefused),
        ("Channel opening failure: channel 3 error (2) Network is unreachable", .networkUnreachable),
        ("Channel opening failure: channel 3 error (2) No route to host", .hostUnreachable),
        ("Channel opening failure: channel 3 error (2) Name or service not known", .hostUnreachable),
        ("Channel opening failure: channel 3 error (2) nodename nor servname provided, or not known", .hostUnreachable),
        ("Channel opening failure: channel 3 error (2) Operation timed out", .hostUnreachable),
        ("Channel opening failure: channel 3 error (3) unknown channel type", .generalFailure),
        ("Channel opening failure: channel 3 error (4) resource shortage", .generalFailure),
        ("Remote channel is closed", .generalFailure),
    ])
    func refusedTunnelGetsTheReplyForItsReason(_ message: String, _ reply: SOCKS5.Reply) {
        #expect(SOCKS5.Reply(openFailure: SSHError.channelRefused(message)) == reply)
    }

    @Test func lostConnectionIsAGeneralFailure() {
        #expect(SOCKS5.Reply(openFailure: SSHError.connectionLost("the network dropped it")) == .generalFailure)
        #expect(SOCKS5.Reply(openFailure: CancellationError()) == .generalFailure)
    }

    @Test func openFailureCodeIsLibsshsNumber() {
        #expect(SSHConnection.openFailureCode("Channel opening failure: channel 43 error (2) Connection refused") == 2)
        #expect(SSHConnection.openFailureCode("Channel opening failure: channel 0 error (1) open failed") == 1)
        #expect(SSHConnection.openFailureCode("Remote channel is closed") == nil)
    }

    // MARK: - Random bytes

    /// Random bytes, and valid handshakes with bytes changed, cut short or repeated, fed in pieces of
    /// 1 to 16 bytes, never trap, and what the handshake says follows its rules: it ends once, sends
    /// at most a method selection and one reply, and a destination's port and address are what the
    /// bytes said. Seeded, so that a failure repeats. The fuzz target Fuzz/SOCKS5 checks the same.
    @Test func randomBytesNeverTrap() {
        var random = SeededRandom(seed: 38)
        let name = Array("example.com".utf8)
        let valid: [[UInt8]] = [
            [5, 1, 0] + Self.request([0x01, 127, 0, 0, 1], port: 22),
            [5, 2, 2, 0] + Self.request([0x03, UInt8(name.count)] + name, port: 443),
            [5, 1, 0] + Self.request([0x04] + [UInt8](repeating: 0, count: 15) + [1], port: 8080) + [1, 2, 3],
        ]
        for round in 0..<3000 {
            var bytes: [UInt8]
            if round % 3 == 0 {
                bytes = (0..<Int.random(in: 0..<300, using: &random)).map { _ in
                    UInt8.random(in: 0...255, using: &random)
                }
            } else {
                bytes = valid[Int.random(in: 0..<valid.count, using: &random)]
                for _ in 0..<Int.random(in: 1...4, using: &random) where !bytes.isEmpty {
                    let index = Int.random(in: 0..<bytes.count, using: &random)
                    switch Int.random(in: 0..<3, using: &random) {
                    case 0: bytes[index] = UInt8.random(in: 0...255, using: &random)
                    case 1: bytes.removeSubrange(index...)
                    default: bytes.insert(contentsOf: Array(bytes[index...].prefix(8)), at: index)
                    }
                }
            }
            Self.checkHandshake(bytes, pieces: &random)
        }
    }

    /// Feeds `bytes` to a handshake in random pieces and checks its rules.
    private static func checkHandshake(_ bytes: [UInt8], pieces random: inout SeededRandom) {
        var handshake = SOCKS5Handshake()
        var sent: [UInt8] = []
        var outcome = SOCKS5Handshake.Outcome.pending
        var fed = 0
        while fed < bytes.count, outcome == .pending {
            let count = min(Int.random(in: 1...16, using: &random), bytes.count - fed)
            let step = handshake.receive(Array(bytes[fed..<(fed + count)]))
            fed += count
            sent += step.send
            outcome = step.outcome
        }
        #expect(sent.count <= 2 + 10)
        #expect(handshake.isDone == (outcome != .pending))
        if case .connect(let destination, let rest) = outcome {
            #expect(rest.count <= bytes.count)
            #expect(Array(bytes[(fed - rest.count)..<fed]) == rest)
            #expect(!destination.address.isEmpty)
            if case .domainName(let name) = destination.host {
                #expect(name.utf8.allSatisfy { (0x21...0x7E).contains($0) })
            }
        }
    }

    // MARK: - Helpers

    /// A CONNECT request for `address`, its type byte first, and `port`.
    private static func request(_ address: [UInt8], port: UInt16) -> [UInt8] {
        [5, 1, 0] + address + [UInt8(port >> 8), UInt8(port & 0xFF)]
    }

    /// The step that a greeting offering no authentication, then a CONNECT request for `address`
    /// and `port`, ends on.
    private static func connect(_ address: [UInt8], port: UInt16) -> SOCKS5Handshake.Step {
        var handshake = SOCKS5Handshake()
        let greeting = handshake.receive([5, 1, 0])
        #expect(greeting.send == [5, 0])
        return handshake.receive(request(address, port: port))
    }
}
