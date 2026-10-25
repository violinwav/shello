import Foundation
import ShelloModel
import Synchronization
import Testing

@testable import ShelloSSH

/// Signing in through an SSH agent (STACK section 7.3) as libssh does it: it asks the agent for its
/// keys, offers them to the server, and has the agent sign. The agent here is a stand-in that holds
/// no private key, so these tests cover what happens before and around the signature;
/// ShelloCoreTests sign in through Shello's own agent and its key store. Both test servers take the
/// fixture key, so these run in CI too.
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(1)))
struct AgentAuthenticationTests {
    /// The server takes the agent's key, and the agent refuses to sign: libssh only says it failed.
    @Test func agentThatDoesNotSignFailsTheSignIn() async throws {
        let agent = try StandInAgent(keys: [TestServer.clientPublicKey])
        let connection = TestServer.connection()
        _ = try await connection.connect()

        await #expect(throws: SSHError.signingFailed) {
            try await connection.authenticate(agentSocket: agent.clientSocket)
        }

        #expect(agent.requests == [11, 13])
        await connection.close()
    }

    @Test func agentWithoutKeysIsRefused() async throws {
        let agent = try StandInAgent(keys: [])
        let connection = TestServer.connection()
        _ = try await connection.connect()

        await #expect(throws: SSHError.authenticationFailed) {
            try await connection.authenticate(agentSocket: agent.clientSocket)
        }

        #expect(agent.requests == [11])
        await connection.close()
    }

    /// The server does not take a key it does not know, and libssh asks for no signature.
    @Test func keyTheServerDoesNotKnowIsRefused() async throws {
        let agent = try StandInAgent(keys: [TestServer.hostKeyB.wireRepresentation])
        let connection = TestServer.connection()
        _ = try await connection.connect()

        await #expect(throws: SSHError.authenticationFailed) {
            try await connection.authenticate(agentSocket: agent.clientSocket)
        }

        #expect(agent.requests == [11])
        await connection.close()
    }

    /// The connection takes the socket, and closes it, whatever happens.
    @Test func closedConnectionClosesTheAgentsSocket() async throws {
        let agent = try StandInAgent(keys: [])
        let connection = TestServer.connection()
        await connection.close()

        await #expect(throws: SSHError.closed) {
            try await connection.authenticate(agentSocket: agent.clientSocket)
        }

        #expect(agent.waitUntilClientIsGone())
    }
}

extension TestServer {
    /// TestServers/keys/client_ed25519.pub in SSH's wire format.
    static let clientPublicKey = Data(
        base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAILkB8UyMQ8FNO9mi2uEkWkVrX5jc0l1kHqB4VMnsnsw5")!
}

/// A stand-in for an SSH agent, on its own thread, at one end of a pair of sockets: it lists `keys`
/// and refuses every other request, signing included (draft-ietf-sshm-ssh-agent).
final class StandInAgent: Sendable {
    /// The end for the client, which the connection takes over.
    let clientSocket: Int32
    private let agentSocket: Int32
    private let recorded = Mutex<[UInt8]>([])
    private let clientIsGone = Mutex(false)

    init(keys: [Data]) throws {
        var ends: [Int32] = [-1, -1]
        guard unsafe socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
            throw SSHError.system("socketpair", errno)
        }
        var on: Int32 = 1
        for end in ends {
            _ = unsafe setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        clientSocket = ends[0]
        agentSocket = ends[1]
        var identities: [UInt8] = [12] + Self.uint32(keys.count)
        for key in keys {
            identities += Self.string(Array(key)) + Self.string(Array("stand-in".utf8))
        }
        let reply = identities
        Thread.detachNewThread { [self] in serve(identitiesAnswer: reply) }
    }

    /// The type of each request, in order.
    var requests: [UInt8] { recorded.withLock { $0 } }

    /// Whether the client closed its end within five seconds.
    func waitUntilClientIsGone() -> Bool {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if clientIsGone.withLock({ $0 }) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func serve(identitiesAnswer: [UInt8]) {
        defer {
            clientIsGone.withLock { $0 = true }
            close(agentSocket)
        }
        while let length = read(4).map(Self.uint32), let message = read(Int(length)), let type = message.first {
            recorded.withLock { $0.append(type) }
            let reply = type == 11 ? identitiesAnswer : [5]
            guard write(Self.uint32(reply.count) + reply) else { return }
        }
    }

    /// Exactly `count` bytes, or nil once the client is gone.
    private func read(_ count: Int) -> [UInt8]? {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: max(count, 1))
        while bytes.count < count {
            let wanted = count - bytes.count
            let received = unsafe buffer.withUnsafeMutableBytes { unsafe recv(agentSocket, $0.baseAddress, wanted, 0) }
            guard received > 0 else {
                if received < 0, errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            bytes += buffer.prefix(received)
        }
        return bytes
    }

    private func write(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let count = unsafe bytes[sent...].withUnsafeBytes { unsafe send(agentSocket, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }

    private static func uint32(_ value: Int) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    private static func uint32(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ bytes: [UInt8]) -> [UInt8] {
        uint32(bytes.count) + bytes
    }
}
