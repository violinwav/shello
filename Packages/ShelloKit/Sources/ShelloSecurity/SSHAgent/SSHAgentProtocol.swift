// The SSH agent protocol (draft-ietf-sshm-ssh-agent), written in-house (STACK sections 2 and 7.3):
// the messages Shello's SSH agent reads and writes. Requests come from libssh today, and from
// servers once agent forwarding comes (v1), so everything here reads untrusted bytes and must
// neither trap nor grow without bound, whatever it is given. Fuzz/SSHAgentProtocol fuzzes it.
//
// This file uses the standard library only, so that the fuzz target builds it with the swift.org
// toolchain on Linux as it is (Fuzz/README.md).

/// The numbers of the agent protocol's messages that Shello's agent reads or writes (draft section
/// 6.1).
enum SSHAgentMessageType: UInt8 {
    /// SSH_AGENT_FAILURE: the agent did not do what it was asked.
    case failure = 5
    /// SSH_AGENTC_REQUEST_IDENTITIES: which keys the agent holds.
    case requestIdentities = 11
    /// SSH_AGENT_IDENTITIES_ANSWER: the keys, each with its comment.
    case identitiesAnswer = 12
    /// SSH_AGENTC_SIGN_REQUEST: a signature with one of the keys.
    case signRequest = 13
    /// SSH_AGENT_SIGN_RESPONSE: the signature.
    case signResponse = 14
    /// SSH_AGENTC_EXTENSION: a request that the protocol leaves to extensions.
    case `extension` = 27
}

/// A request to the agent, read from a message's contents (draft section 4).
enum SSHAgentRequest: Hashable, Sendable {
    /// The keys the agent holds (section 4.4).
    case requestIdentities
    /// A signature of `data` with the key whose public key in SSH's wire format is `keyBlob`
    /// (section 4.5). `flags` choose an RSA key's hash.
    case sign(keyBlob: [UInt8], data: [UInt8], flags: UInt32)
    /// An extension called `name` (section 4.7), which the agent supports none of.
    case `extension`(name: [UInt8])
    /// Any other request, such as adding or removing keys, or locking the agent, which Shello's
    /// agent refuses: its keys come from the key store only.
    case unsupported(type: UInt8)

    /// Reads the request in `message`, a message's contents: its type, then the type's fields.
    /// - Throws: `SSHAgentProtocolError` for a message that is empty, ends early, or goes on after
    ///   its fields.
    init(message: some Collection<UInt8>) throws(SSHAgentProtocolError) {
        guard !message.isEmpty else { throw .empty }
        var reader = SSHAgentReader(message)
        let type = try reader.readByte()
        switch SSHAgentMessageType(rawValue: type) {
        case .requestIdentities:
            self = .requestIdentities
        case .signRequest:
            let keyBlob = try reader.readString()
            let data = try reader.readString()
            let flags = try reader.readUInt32()
            self = .sign(keyBlob: keyBlob, data: data, flags: flags)
        case .extension:
            // The extension's own fields follow its name; no extension is supported, so they are
            // not read.
            self = .extension(name: try reader.readString())
            return
        default:
            // The other requests are refused whatever they hold.
            self = .unsupported(type: type)
            return
        }
        guard reader.isAtEnd else { throw .trailingBytes }
    }
}

/// A key the agent offers: its public key in SSH's wire format, and its comment.
struct SSHAgentIdentity: Hashable, Sendable {
    let keyBlob: [UInt8]
    let comment: String
}

/// The agent's reply to a request (draft section 4).
enum SSHAgentReply: Hashable, Sendable {
    /// SSH_AGENT_FAILURE: the request was refused, or failed.
    case failure
    /// SSH_AGENT_IDENTITIES_ANSWER, with the keys the agent offers.
    case identities([SSHAgentIdentity])
    /// SSH_AGENT_SIGN_RESPONSE, with a signature in SSH's wire format: the algorithm's name, then
    /// the signature, each a `string`.
    case signature([UInt8])

    /// The reply's message contents, without the length that frames it.
    var message: [UInt8] {
        var writer = SSHAgentWriter()
        switch self {
        case .failure:
            writer.write(SSHAgentMessageType.failure.rawValue)
        case .identities(let identities):
            writer.write(SSHAgentMessageType.identitiesAnswer.rawValue)
            writer.write(UInt32(identities.count))
            for identity in identities {
                writer.writeString(identity.keyBlob)
                writer.writeString(Array(identity.comment.utf8))
            }
        case .signature(let signature):
            writer.write(SSHAgentMessageType.signResponse.rawValue)
            writer.writeString(signature)
        }
        return writer.bytes
    }
}

/// Why a message could not be read.
enum SSHAgentProtocolError: Error, Hashable, Sendable {
    /// The message has no type: its length was zero.
    case empty
    /// The message ends before its fields do.
    case truncated
    /// The message goes on after its fields.
    case trailingBytes
    /// A message's length is longer than the agent accepts, `SSHAgentFrames.maximumLength`.
    case tooLong(UInt32)
}

/// Splits the bytes that arrive on the agent's socket into messages: each is a `uint32` length,
/// then that many bytes (draft section 3). Bytes come in pieces of any size.
struct SSHAgentFrames {
    /// The longest message the agent reads, as OpenSSH's agent: 256 KiB. A sign request's data is
    /// an SSH sign-in request, far shorter.
    static let maximumLength: UInt32 = 256 * 1024

    private var buffer: [UInt8] = []
    /// Where the next message starts in `buffer`. The bytes before it were read already, and go
    /// once they are as many as the bytes after it.
    private var start = 0

    /// The bytes received and not read as a message yet.
    var pendingCount: Int { buffer.count - start }

    mutating func append(_ bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    /// The contents of the next complete message, or nil until all of it has arrived.
    /// - Throws: `SSHAgentProtocolError.tooLong` for a length above `maximumLength`; nothing after it
    ///   can be read as a message then.
    mutating func next() throws(SSHAgentProtocolError) -> [UInt8]? {
        guard pendingCount >= 4 else { return nil }
        let length = buffer[start..<start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard length <= Self.maximumLength else { throw .tooLong(length) }
        guard pendingCount - 4 >= Int(length) else { return nil }
        let message = Array(buffer[start + 4..<start + 4 + Int(length)])
        start += 4 + Int(length)
        if start >= buffer.count - start {
            buffer.removeFirst(start)
            start = 0
        }
        return message
    }

    /// `message` framed for the socket: its length as a `uint32`, then its bytes.
    static func frame(_ message: [UInt8]) -> [UInt8] {
        var writer = SSHAgentWriter()
        writer.write(UInt32(message.count))
        return writer.bytes + message
    }
}

/// Reads the SSH wire format (RFC 4251 section 5) from a message, checking every length against
/// what is left.
struct SSHAgentReader {
    private var bytes: ArraySlice<UInt8>

    init(_ bytes: some Collection<UInt8>) {
        self.bytes = Array(bytes)[...]
    }

    var isAtEnd: Bool { bytes.isEmpty }

    mutating func readByte() throws(SSHAgentProtocolError) -> UInt8 {
        guard let byte = bytes.popFirst() else { throw .truncated }
        return byte
    }

    /// A `uint32`: four bytes, the most significant first.
    mutating func readUInt32() throws(SSHAgentProtocolError) -> UInt32 {
        guard bytes.count >= 4 else { throw .truncated }
        let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        bytes = bytes.dropFirst(4)
        return value
    }

    /// A `string`: a `uint32` length, then that many bytes.
    mutating func readString() throws(SSHAgentProtocolError) -> [UInt8] {
        let length = try readUInt32()
        guard UInt64(length) <= UInt64(bytes.count) else { throw .truncated }
        let string = Array(bytes.prefix(Int(length)))
        bytes = bytes.dropFirst(Int(length))
        return string
    }
}

/// Writes the SSH wire format.
struct SSHAgentWriter {
    private(set) var bytes: [UInt8] = []

    mutating func write(_ byte: UInt8) {
        bytes.append(byte)
    }

    /// A `uint32`: four bytes, the most significant first.
    mutating func write(_ value: UInt32) {
        bytes.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    /// A `string`: its length as a `uint32`, then its bytes.
    mutating func writeString(_ string: [UInt8]) {
        write(UInt32(string.count))
        bytes.append(contentsOf: string)
    }
}
