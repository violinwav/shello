import Testing

@testable import ShelloSecurity

/// The SSH agent protocol as Shello's agent reads and writes it (draft-ietf-sshm-ssh-agent): the
/// requests, the replies, and the framing of messages on the socket. Fuzz/SSHAgentProtocol fuzzes
/// the same code with libFuzzer on Linux; `randomBytesNeverTrap` is its short stand-in here.
struct SSHAgentProtocolTests {
    // MARK: - Requests

    @Test func readsARequestForIdentities() throws {
        #expect(try SSHAgentRequest(message: [11]) == .requestIdentities)
    }

    /// As libssh sends it: the key, the data, and the flags.
    @Test func readsASignRequest() throws {
        let message = [13] + string([1, 2, 3]) + string([4, 5]) + uint32(4)

        #expect(try SSHAgentRequest(message: message) == .sign(keyBlob: [1, 2, 3], data: [4, 5], flags: 4))
    }

    @Test func readsAnExtensionByItsName() throws {
        let message = [27] + string(Array("session-bind@openssh.com".utf8)) + [9, 9, 9]

        #expect(try SSHAgentRequest(message: message) == .extension(name: Array("session-bind@openssh.com".utf8)))
    }

    /// Adding, removing and locking keys, and anything unknown, are refused whatever they hold.
    @Test(arguments: [17, 18, 19, 22, 23, 25, 0, 255] as [UInt8])
    func otherRequestsAreUnsupported(_ type: UInt8) throws {
        #expect(try SSHAgentRequest(message: [type, 1, 2, 3]) == .unsupported(type: type))
    }

    @Test func emptyMessageIsRefused() {
        #expect(throws: SSHAgentProtocolError.empty) { try SSHAgentRequest(message: []) }
    }

    /// A sign request whose strings claim more than the message holds.
    @Test(
        arguments: [
            [13], [13, 0, 0, 0], [13, 0, 0, 0, 5, 1, 2], [13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [13, 255, 255, 255, 255, 1], [27, 0, 0, 1, 0],
        ] as [[UInt8]])
    func truncatedRequestIsRefused(_ message: [UInt8]) {
        #expect(throws: SSHAgentProtocolError.truncated) { try SSHAgentRequest(message: message) }
    }

    @Test func requestWithMoreThanItsFieldsIsRefused() {
        #expect(throws: SSHAgentProtocolError.trailingBytes) { try SSHAgentRequest(message: [11, 0]) }
        let sign = [13] + string([1]) + string([2]) + uint32(0) + [0]
        #expect(throws: SSHAgentProtocolError.trailingBytes) { try SSHAgentRequest(message: sign) }
    }

    // MARK: - Replies

    @Test func writesTheIdentitiesWithTheirComments() {
        let reply = SSHAgentReply.identities([
            SSHAgentIdentity(keyBlob: [1, 2], comment: "a"), SSHAgentIdentity(keyBlob: [3], comment: "Grüße"),
        ])

        #expect(
            reply.message == [12] + uint32(2) + string([1, 2]) + string([97]) + string([3])
                + string(Array("Grüße".utf8)))
    }

    @Test func writesASignature() {
        #expect(SSHAgentReply.signature([7, 8, 9]).message == [14] + string([7, 8, 9]))
    }

    @Test func writesAFailure() {
        #expect(SSHAgentReply.failure.message == [5])
    }

    // MARK: - Framing

    /// Messages arrive in pieces of any size, several at once or a byte at a time.
    @Test func framesSplitMessagesArrivingInPieces() throws {
        let stream = SSHAgentFrames.frame([11]) + SSHAgentFrames.frame([13, 1, 2, 3]) + SSHAgentFrames.frame([])
        for pieceSize in [1, 2, 3, 5, stream.count] {
            var frames = SSHAgentFrames()
            var messages: [[UInt8]] = []
            for start in stride(from: 0, to: stream.count, by: pieceSize) {
                frames.append(stream[start..<min(start + pieceSize, stream.count)])
                while let message = try frames.next() {
                    messages.append(message)
                }
            }

            #expect(messages == [[11], [13, 1, 2, 3], []], "pieces of \(pieceSize) bytes")
            #expect(frames.pendingCount == 0)
        }
    }

    /// A length beyond 256 KiB is refused at once, before the bytes it claims arrive.
    @Test func framesRefuseALengthAboveTheMaximum() {
        var frames = SSHAgentFrames()
        frames.append(uint32(Int(SSHAgentFrames.maximumLength) + 1))

        #expect(throws: SSHAgentProtocolError.tooLong(SSHAgentFrames.maximumLength + 1)) { try frames.next() }
    }

    @Test func framesTakeAMessageOfTheMaximumLength() throws {
        var frames = SSHAgentFrames()
        let message = [UInt8](repeating: 13, count: Int(SSHAgentFrames.maximumLength))
        frames.append(SSHAgentFrames.frame(message))

        #expect(try frames.next() == message)
    }

    // MARK: - Untrusted input

    /// The parser's robustness test: random messages, and random streams cut at random places, never
    /// trap, and every message the framing returns fits within the stream. The same input would make
    /// the fuzz target trap in Fuzz/SSHAgentProtocol. The generator is seeded, so a failure repeats.
    @Test func randomBytesNeverTrap() throws {
        var random = SeededRandom(seed: 0x5348_454C_4C4F)
        for _ in 0..<20_000 {
            let count = Int.random(in: 0...64, using: &random)
            var bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
            // Plausible types and lengths reach deeper into the parser than random ones.
            if !bytes.isEmpty, Bool.random(using: &random) {
                bytes[0] = [11, 13, 27].randomElement(using: &random) ?? 13
            }
            if bytes.count > 5, Bool.random(using: &random) {
                bytes.replaceSubrange(1..<5, with: uint32(Int.random(in: 0...(count - 5), using: &random)))
            }
            _ = try? SSHAgentRequest(message: bytes)

            var frames = SSHAgentFrames()
            var received = 0
            var start = 0
            while start < bytes.count {
                let end = min(bytes.count, start + Int.random(in: 1...8, using: &random))
                frames.append(bytes[start..<end])
                start = end
                while let message = try? frames.next() {
                    received += 4 + message.count
                    _ = try? SSHAgentRequest(message: message)
                }
            }
            #expect(received + frames.pendingCount == bytes.count)
        }
    }

    // MARK: - Helpers

    private func uint32(_ value: Int) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    private func string(_ bytes: [UInt8]) -> [UInt8] {
        uint32(bytes.count) + bytes
    }
}

/// A random number generator that repeats its numbers for the same seed (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
