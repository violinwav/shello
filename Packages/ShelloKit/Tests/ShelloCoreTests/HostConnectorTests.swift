import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import Testing

@testable import ShelloCore

/// Connecting to a host against the test server (README sections 3 and 4): the first connection
/// asks to trust the host key, a trusted key connects without asking, and a changed or untrusted key
/// stops the connection before the password is even read. Skipped when the server is not running.
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(1)))
struct HostConnectorTests {
    let test: TestConnector

    init() throws {
        test = try TestConnector()
    }

    @Test(.enabled(if: TestServer.password != nil, TestServer.noPasswords))
    func firstConnectionAsksToTrustTheHostKeyThenSignsIn() async throws {
        let questions = TrustQuestions(answer: true)
        let host = try test.host(password: TestServer.password)

        let connection = try await test.connector.connect(to: host, askToTrust: questions.ask)

        #expect(questions.keys == [TestServer.hostKeyA])
        #expect(try await test.hostKeys.trustedKey(of: host.server)?.key == TestServer.hostKeyA)
        let whoami = try await connection.run("whoami")
        #expect(String(decoding: whoami.output, as: UTF8.self) == "\(TestServer.user)\n")
        await connection.close()
    }

    /// Trust is kept once given, whether or not the server then takes the password, as a server that
    /// takes keys only does not.
    @Test func trustingTheHostKeyKeepsItForTheServer() async throws {
        let questions = TrustQuestions(answer: true)
        let host = try test.host(password: TestServer.password ?? "not-the-password")

        let connection = try? await test.connector.connect(to: host, askToTrust: questions.ask)
        await connection?.close()

        #expect(questions.keys == [TestServer.hostKeyA])
        #expect(try await test.hostKeys.trustedKey(of: host.server)?.key == TestServer.hostKeyA)
    }

    @Test(.enabled(if: TestServer.password != nil, TestServer.noPasswords))
    func trustedServerConnectsWithoutAsking() async throws {
        let questions = TrustQuestions(answer: false)
        let host = try test.host(password: TestServer.password)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)

        let connection = try await test.connector.connect(to: host, askToTrust: questions.ask)

        #expect(questions.keys.isEmpty)
        await connection.close()
    }

    @Test func untrustedHostKeyStopsTheConnectionBeforeThePasswordIsRead() async throws {
        let questions = TrustQuestions(answer: false)
        let host = try test.host(password: "never read")

        await #expect(throws: ConnectError.hostKeyNotTrusted) {
            try await test.connector.connect(to: host, askToTrust: questions.ask)
        }

        #expect(questions.keys == [TestServer.hostKeyA])
        #expect(try await test.hostKeys.trustedKey(of: host.server) == nil)
        #expect(test.keychain.reads == 0)
    }

    /// The server presents key a, while key b is trusted: the connection is blocked, nobody is
    /// asked, and the password is never read, so it cannot reach whoever is in between.
    @Test func changedHostKeyBlocksTheConnectionBeforeThePasswordIsRead() async throws {
        let questions = TrustQuestions(answer: true)
        let host = try test.host(password: "never read")
        try await test.hostKeys.trust(TestServer.hostKeyB, of: host.server)
        let trusted = try #require(try await test.hostKeys.trustedKey(of: host.server))

        await #expect(
            throws: ConnectError.hostKeyChanged(host.server, trusted: trusted, presented: TestServer.hostKeyA)
        ) {
            try await test.connector.connect(to: host, askToTrust: questions.ask)
        }

        #expect(questions.keys.isEmpty)
        #expect(try await test.hostKeys.trustedKey(of: host.server) == trusted)
        #expect(test.keychain.reads == 0)
    }

    /// Trust belongs to the server, so another host on it, as another user, is not asked again.
    @Test func trustCoversEveryHostOfTheServer() async throws {
        let questions = TrustQuestions(answer: true)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: TestServer.server)
        var host = try test.host(password: TestServer.password ?? "not-the-password")
        host.address = "LOCALHOST"

        let connection = try? await test.connector.connect(to: host, askToTrust: questions.ask)
        await connection?.close()

        #expect(questions.keys.isEmpty)
    }
}

/// Hosts Shello cannot sign in to yet fail before anything goes over the network: each points at a
/// port nothing answers on, which would fail otherwise.
struct HostConnectorPreflightTests {
    let test: TestConnector

    init() throws {
        test = try TestConnector()
    }

    @Test func hostWithoutASavedPasswordFails() async throws {
        let host = Self.unreachable(try test.host(password: nil))

        await #expect(throws: ConnectError.noPassword) {
            try await test.connector.connect(to: host) { _, _ in true }
        }
    }

    @Test(arguments: [AuthMethod.sshKey, .keyboardInteractive])
    func methodsThatComeLaterFail(_ method: AuthMethod) async throws {
        var host = Self.unreachable(try test.host(password: "unused"))
        host.authMethod = method

        await #expect(throws: ConnectError.unsupportedAuthMethod(method)) {
            try await test.connector.connect(to: host) { _, _ in true }
        }
    }

    @Test func vncHostFails() async throws {
        var host = Self.unreachable(try test.host(password: "unused"))
        host.protocol = .vnc

        await #expect(throws: ConnectError.unsupportedProtocol(.vnc)) {
            try await test.connector.connect(to: host) { _, _ in true }
        }
    }

    @Test func hostWithoutAUserFails() async throws {
        var host = Self.unreachable(try test.host(password: "unused"))
        host.username = ""

        await #expect(throws: ConnectError.noUser) {
            try await test.connector.connect(to: host) { _, _ in true }
        }
    }

    @Test func lockedShelloFails() async throws {
        let host = Self.unreachable(try test.host(password: "unused"))
        test.unlockWindow.close()

        await #expect(throws: UnlockWindowClosed.self) {
            try await test.connector.connect(to: host) { _, _ in true }
        }
    }

    /// Mosh starts over SSH, so a Mosh host connects over SSH until Mosh comes (v1).
    @Test func moshHostGetsAsFarAsConnecting() async throws {
        var host = Self.unreachable(try test.host(password: "unused"))
        host.protocol = .mosh

        await #expect(throws: SSHError.self) {
            try await test.connector.connect(to: host) { _, _ in true }
        }
    }

    private static func unreachable(_ host: Host) -> Host {
        var host = host
        host.address = "127.0.0.1"
        host.port = 9
        return host
    }
}
