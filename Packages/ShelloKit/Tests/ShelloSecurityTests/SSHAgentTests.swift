import CryptoKit
import Foundation
import Testing

@testable import ShelloSecurity

/// Shello's SSH agent (STACK section 7.3): it offers the keys it was made with, signs with them
/// through the key store, as their signing policy says, and refuses everything else. The key store
/// is in memory, with LocalAuthentication's stand-in.
struct SSHAgentTests {
    let authentication = TestAuthentication()
    let window: UnlockWindow
    let store: SSHKeyStore

    init() {
        window = UnlockWindow(authentication: authentication)
        store = .inMemory(unlockWindow: window, authentication: authentication)
    }

    @Test func listsTheKeysItOffers() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.ed25519, comment: "work", signingPolicy: .whileUnlocked)
        _ = try await store.generate(.ed25519, comment: "not offered", signingPolicy: .whileUnlocked)
        let agent = SSHAgent(keys: store, identities: [key])

        let reply = await agent.answer([11])

        let expected = SSHAgentReply.identities([
            SSHAgentIdentity(keyBlob: Array(key.publicKey.wireRepresentation), comment: "work")
        ])
        #expect(reply == expected.message)
    }

    /// What libssh asks to sign comes back signed by the key, in SSH's wire format.
    @Test func signsWithAKeyItOffers() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.ed25519, comment: "work", signingPolicy: .whileUnlocked)
        let agent = SSHAgent(keys: store, identities: [key])
        let data = Array("session identifier and sign-in request".utf8)

        let reply = await agent.answer(Self.signRequest(key, data))

        #expect(reply.first == 14)
        var reader = SSHReader(Data(reply.dropFirst()))
        let signature = try ParsedSSHSignature(try reader.readString())
        #expect(reader.isAtEnd)
        #expect(signature.algorithm == "ssh-ed25519")
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: key.publicKey.wireRepresentation.suffix(32))
        #expect(publicKey.isValidSignature(signature.blob, for: Data(data)))
        #expect(agent.signingFailure == nil)
    }

    /// A key of the store that the agent was not made with is out of reach, as is any other.
    @Test func refusesToSignWithAKeyItDoesNotOffer() async throws {
        try await window.open(reason: "Unlock Shello")
        let offered = try await store.generate(.ed25519, comment: "offered", signingPolicy: .whileUnlocked)
        let other = try await store.generate(.ed25519, comment: "other", signingPolicy: .whileUnlocked)
        let agent = SSHAgent(keys: store, identities: [offered])

        #expect(await agent.answer(Self.signRequest(other, [1, 2, 3])) == [5])
    }

    /// While app lock is engaged, a key that signs while Shello is unlocked does not sign, and the
    /// agent knows why.
    @Test func refusesToSignWhileShelloIsLocked() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.ed25519, comment: "work", signingPolicy: .whileUnlocked)
        let agent = SSHAgent(keys: store, identities: [key])
        window.close()

        #expect(await agent.answer(Self.signRequest(key, [1, 2, 3])) == [5])
        #expect(agent.signingFailure is UnlockWindowClosed)
    }

    /// A key that signs on every use asks the user, for the reason the agent was given.
    @Test func everyUseKeyAsksForTheAgentsReason() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.ed25519, comment: "work", signingPolicy: .everyUse)
        let agent = SSHAgent(keys: store, identities: [key], reason: "Sign in to nas.")

        #expect(await agent.answer(Self.signRequest(key, [1, 2, 3])).first == 14)
        #expect(authentication.reasons.last == "Sign in to nas.")

        authentication.answer(.failure(.cancelled))
        #expect(await agent.answer(Self.signRequest(key, [1, 2, 3])) == [5])
        #expect(agent.signingFailure as? UnlockError == .cancelled)
    }

    /// Its keys come from the key store only: adding, removing and locking are refused, and so are
    /// extensions and what cannot be read.
    @Test(
        arguments: [[17, 0, 0, 0, 0], [18], [19], [22, 0, 0, 0, 0], [25], [27, 0, 0, 0, 1, 120], [13, 0], []]
            as [[UInt8]])
    func refusesEverythingElse(_ request: [UInt8]) async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.ed25519, comment: "work", signingPolicy: .whileUnlocked)
        let agent = SSHAgent(keys: store, identities: [key])

        #expect(await agent.answer(request) == [5])
        #expect(try store.keys().count == 1)
    }

    // MARK: - The socket

    /// A client writes framed requests to its end and reads framed replies, as libssh does.
    @Test(.timeLimit(.minutes(1)))
    func answersOnItsSocket() async throws {
        try await window.open(reason: "Unlock Shello")
        let key = try await store.generate(.ed25519, comment: "work", signingPolicy: .whileUnlocked)
        let agent = SSHAgent(keys: store, identities: [key])
        let client = try SocketClient(socket: agent.listen())
        defer { client.close() }

        // Two requests at once, the second answered after the first.
        try client.send(SSHAgentFrames.frame([11]) + SSHAgentFrames.frame(Self.signRequest(key, [42])))

        let identities = try #require(client.receiveMessage())
        #expect(identities.first == 12)
        let signature = try #require(client.receiveMessage())
        #expect(signature.first == 14)

        agent.close()
        #expect(client.receiveMessage() == nil)
    }

    /// Closing the agent while an every-use key waits for Face ID ends the prompt and the request at
    /// once: the client reads the end of the socket. libssh waits for the answer on the connection's
    /// queue, so closing a tab, or the app going to the background, never waits for the user.
    @Test(.timeLimit(.minutes(1)))
    func closingWhileFaceIDIsUpEndsThePromptAndTheRequest() async throws {
        let authentication = PendingAuthentication()
        let window = UnlockWindow(authentication: authentication)
        window.openWithoutAuthentication()
        let store = SSHKeyStore.inMemory(unlockWindow: window, authentication: authentication)
        let key = try await store.generate(.ed25519, comment: "work", signingPolicy: .everyUse)
        let agent = SSHAgent(keys: store, identities: [key], reason: "Sign in to nas.")
        let client = try SocketClient(socket: agent.listen())
        defer { client.close() }
        try client.send(SSHAgentFrames.frame(Self.signRequest(key, [1, 2, 3])))
        await authentication.waitForPrompt()

        let clock = ContinuousClock()
        let closed = clock.now
        agent.close()

        #expect(client.receiveMessage() == nil)
        #expect(clock.now - closed < .seconds(2))
        while authentication.openPromptCount > 0, clock.now - closed < .seconds(5) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(authentication.openPromptCount == 0, "The Face ID prompt is still up")
        #expect(authentication.promptCount == 1)
    }

    /// A message longer than the agent reads ends the conversation: nothing after it can be read.
    @Test(.timeLimit(.minutes(1)))
    func closesOnAMessageTooLongToRead() throws {
        let agent = SSHAgent(keys: store, identities: [])
        let client = try SocketClient(socket: agent.listen())
        defer { client.close() }

        try client.send([0xFF, 0xFF, 0xFF, 0xFF, 11])

        #expect(client.receiveMessage() == nil)
    }

    // MARK: - Helpers

    /// A sign request for `data` with `key`, as libssh sends one.
    private static func signRequest(_ key: SSHKey, _ data: [UInt8]) -> [UInt8] {
        var writer = SSHAgentWriter()
        writer.write(UInt8(13))
        writer.writeString(Array(key.publicKey.wireRepresentation))
        writer.writeString(data)
        writer.write(UInt32(0))
        return writer.bytes
    }
}

/// The client's end of the agent's socket, read and written as libssh does: blocking until it is
/// done, here with a five-second limit on each read.
final class SocketClient: Sendable {
    private let socket: Int32

    init(socket: Int32) throws {
        self.socket = socket
        let flags = fcntl(socket, F_GETFL)
        _ = fcntl(socket, F_SETFL, flags & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = unsafe setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ bytes: [UInt8]) throws {
        let sent = unsafe bytes.withUnsafeBytes { unsafe write(socket, $0.baseAddress, $0.count) }
        guard sent == bytes.count else { throw POSIXError(.EIO) }
    }

    /// The next message's contents, or nil once the agent closed its end, or after five seconds.
    func receiveMessage() -> [UInt8]? {
        guard let length = receive(4) else { return nil }
        return receive(Int(length.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
    }

    func close() {
        Darwin.close(socket)
    }

    private func receive(_ count: Int) -> [UInt8]? {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: max(count, 1))
        while bytes.count < count {
            let wanted = count - bytes.count
            let received = unsafe buffer.withUnsafeMutableBytes { unsafe read(socket, $0.baseAddress, wanted) }
            guard received > 0 else { return nil }
            bytes += buffer.prefix(received)
        }
        return bytes
    }
}
