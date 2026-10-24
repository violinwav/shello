import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloStorage
import Synchronization
import Testing

@testable import ShelloCore

/// Signing in to a host as it says (README sections 4 and 13): with its SSH key through Shello's SSH
/// agent, with keyboard-interactive and its one-time codes, and with a further method when the server
/// asks for one. The SSH key tests run against CI's sshd too; keyboard-interactive needs the Docker
/// servers, whose sshd asks through PAM.
@Suite(.serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning }, .timeLimit(.minutes(1)))
struct SignInTests {
    let test: TestConnector

    init() throws {
        test = try TestConnector()
    }

    // MARK: - SSH keys

    /// The host's key signs through the agent, which the key store backs (STACK section 7.3).
    @Test func sshKeyHostSignsInThroughTheAgent() async throws {
        let host = try test.keyHost()
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)

        let connection = try await test.connector.connect(to: host) { _, _ in false }

        let whoami = try await connection.run("whoami")
        #expect(String(decoding: whoami.output, as: UTF8.self) == "\(TestServer.user)\n")
        await connection.close()
    }

    /// A key that signs on every use asks for Face ID, naming the host, for each sign-in.
    @Test func everyUseKeyAsksNamingTheHost() async throws {
        let test = try TestConnector(clientKeyPolicy: .everyUse)
        let host = try test.keyHost()
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)

        let connection = try await test.connector.connect(to: host) { _, _ in false }

        #expect(test.authentication.reasons == ["Sign in to test server with “shello-test-client”."])
        await connection.close()
    }

    /// Cancelling Face ID cancels the sign-in, rather than failing it.
    @Test func cancellingFaceIDCancelsTheSignIn() async throws {
        let test = try TestConnector(clientKeyPolicy: .everyUse)
        let host = try test.keyHost()
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        test.authentication.answer(.failure(.cancelled))

        await #expect(throws: ConnectError.signInCancelled) {
            try await test.connector.connect(to: host) { _, _ in false }
        }
    }

    // MARK: - The algorithm policy

    /// A host's own lists reach the connection (README section 14): offered curve25519-sha256 only,
    /// OpenSSH 10 takes it over its post-quantum default.
    @Test func hostsOwnListsReachTheConnection() async throws {
        let host = try test.keyHost()
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)

        let connection = try await test.connector.connect(
            to: host, algorithms: AlgorithmOverrides(keyExchanges: ["curve25519-sha256"])
        ) { _, _ in false }

        #expect(await connection.keyExchange == KeyExchange(name: "curve25519-sha256", isPostQuantum: false))
        await connection.close()
    }

    /// The trust store decides which host key algorithms the server is asked for first.
    @Test func trustedKeyTypeIsAskedForFirst() async throws {
        let trusted = HostKey(
            algorithm: "ecdsa-sha2-nistp256", wireRepresentation: Data([1]), fingerprint: "SHA256:AQ")
        try await test.hostKeys.trust(trusted, of: TestServer.server)

        let policy = try await test.connector.algorithms(for: TestServer.server, overriddenBy: .none)

        #expect(policy.hostKeyAlgorithms.first == "ecdsa-sha2-nistp256")
        #expect(policy.keyExchanges == AlgorithmPolicy.standard.keyExchanges)
    }

    // MARK: - Keyboard-interactive

    /// A password, then a one-time code that shows as it is typed, each in a round of its own, as
    /// sshd asks through PAM.
    @Test(.enabled(if: TestServer.password != nil, TestServer.noPasswords))
    func keyboardInteractiveAsksForThePasswordThenTheOneTimeCode() async throws {
        var host = try test.host(password: nil, user: "shello-otp")
        host.authMethod = .keyboardInteractive
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let user = User(answers: ["shello-test-password", OneTimeCode.current()])

        let connection = try await test.connector.connect(to: host, askToTrust: { _, _ in false }, answer: user.answer)

        #expect(
            user.questions.map(\.prompts) == [
                [KeyboardInteractivePrompt(text: "Password:", showsAnswer: false)],
                [KeyboardInteractivePrompt(text: "Verification code:", showsAnswer: true)],
            ])
        let whoami = try await connection.run("whoami")
        #expect(String(decoding: whoami.output, as: UTF8.self) == "shello-otp\n")
        await connection.close()
    }

    /// Two-factor sign-in: the server takes the SSH key, then asks for a one-time code.
    @Test(.enabled(if: TestServer.password != nil, TestServer.noPasswords))
    func twoFactorServerAsksForTheOneTimeCodeAfterTheKey() async throws {
        let host = try test.keyHost(user: "shello-2fa")
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let user = User(answers: [OneTimeCode.current()])

        let connection = try await test.connector.connect(to: host, askToTrust: { _, _ in false }, answer: user.answer)

        #expect(
            user.questions.map(\.prompts) == [
                [KeyboardInteractivePrompt(text: "Verification code:", showsAnswer: true)]
            ])
        let whoami = try await connection.run("whoami")
        #expect(String(decoding: whoami.output, as: UTF8.self) == "shello-2fa\n")
        await connection.close()
    }

    /// The oldest OpenSSH Shello supports, with the same two factors.
    @Test(
        .enabled(if: TestServer.password != nil, TestServer.noPasswords),
        .enabled(TestServer.openSSH8NotRunning) { await TestServer.isOpenSSH8Running })
    func openSSH88AsksForTheOneTimeCodeAfterTheKey() async throws {
        let host = try test.keyHost(port: TestServer.openSSH8Port, user: "shello-2fa")
        let user = User(answers: [OneTimeCode.current()])

        let connection = try await test.connector.connect(to: host, askToTrust: { _, _ in true }, answer: user.answer)

        #expect(user.questions.count == 1)
        #expect(await connection.keyExchange?.name == "curve25519-sha256")
        await connection.close()
    }

    @Test(.enabled(if: TestServer.password != nil, TestServer.noPasswords))
    func cancellingTheQuestionsCancelsTheSignIn() async throws {
        var host = try test.host(password: nil)
        host.authMethod = .keyboardInteractive
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)

        await #expect(throws: ConnectError.signInCancelled) {
            try await test.connector.connect(to: host, askToTrust: { _, _ in false }, answer: { _ in nil })
        }
    }

    @Test(.enabled(if: TestServer.password != nil, TestServer.noPasswords))
    func wrongOneTimeCodeIsRefused() async throws {
        var host = try test.host(password: nil, user: "shello-otp")
        host.authMethod = .keyboardInteractive
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        let user = User(answers: ["shello-test-password", "000000"])

        await #expect(throws: SSHError.authenticationFailed) {
            try await test.connector.connect(to: host, askToTrust: { _, _ in false }, answer: user.answer)
        }
    }

    // MARK: - A changed host key

    /// The user replaces the trusted key, after LocalAuthentication, and the next connection goes
    /// through (README section 3).
    @Test func replacedHostKeyLetsTheConnectionThrough() async throws {
        let host = try test.keyHost()
        try await test.hostKeys.trust(TestServer.hostKeyB, of: host.server)
        let change = await #expect(throws: ConnectError.self) {
            try await test.connector.connect(to: host) { _, _ in false }
        }
        guard case .hostKeyChanged(let server, let trusted, let presented) = change else {
            Issue.record("Not blocked as a changed host key: \(String(describing: change))")
            return
        }

        try await test.connector.replaceTrustedKey(trusted, with: presented, of: server)
        let connection = try await test.connector.connect(to: host) { _, _ in false }

        #expect(test.authentication.reasons == ["Replace the trusted host key of localhost:2222."])
        #expect(try await test.hostKeys.trustedKey(of: server)?.key == TestServer.hostKeyA)
        await connection.close()
    }
}

/// Replacing a trusted host key (README section 3, STACK section 7.2): an explicit action, which
/// the screen asks for, then LocalAuthentication, every time. No server is needed.
struct HostKeyReplacementTests {
    let test: TestConnector
    let server = Server(address: "nas.lan", port: 22)

    init() throws {
        test = try TestConnector()
    }

    @Test func replacingAsksForFaceIDThenTrustsTheNewKey() async throws {
        try await test.hostKeys.trust(TestServer.hostKeyB, of: server)
        let trusted = try #require(try await test.hostKeys.trustedKey(of: server))

        try await test.connector.replaceTrustedKey(trusted, with: TestServer.hostKeyA, of: server)

        #expect(test.authentication.reasons == ["Replace the trusted host key of nas.lan:22."])
        #expect(try await test.hostKeys.trustedKey(of: server)?.key == TestServer.hostKeyA)
    }

    /// Unlocked Shello is not enough: LocalAuthentication asks, and without it the key stays.
    @Test(arguments: [UnlockError.cancelled, .failed])
    func keyStaysWithoutFaceID(_ error: UnlockError) async throws {
        try await test.hostKeys.trust(TestServer.hostKeyB, of: server)
        let trusted = try #require(try await test.hostKeys.trustedKey(of: server))
        test.authentication.answer(.failure(error))

        await #expect(throws: error) {
            try await test.connector.replaceTrustedKey(trusted, with: TestServer.hostKeyA, of: server)
        }
        #expect(try await test.hostKeys.trustedKey(of: server) == trusted)
    }

    /// A device without a passcode cannot ask anyone, as with app lock: the confirmation is enough.
    @Test func deviceWithoutAPasscodeReplacesWithoutAsking() async throws {
        try await test.hostKeys.trust(TestServer.hostKeyB, of: server)
        let trusted = try #require(try await test.hostKeys.trustedKey(of: server))
        test.authentication.setCapability(.passcodeNotSet)

        try await test.connector.replaceTrustedKey(trusted, with: TestServer.hostKeyA, of: server)

        #expect(test.authentication.reasons.isEmpty)
        #expect(try await test.hostKeys.trustedKey(of: server)?.key == TestServer.hostKeyA)
    }
}

/// The answers the user gives to keyboard-interactive questions, and the questions they saw.
final class User: Sendable {
    private let answers: [String]
    private let asked = Mutex<[KeyboardInteractiveChallenge]>([])

    init(answers: [String]) {
        self.answers = answers
    }

    var questions: [KeyboardInteractiveChallenge] { asked.withLock { $0 } }

    /// The next answers, one for each question of the round.
    func answer(_ challenge: KeyboardInteractiveChallenge) -> [Secret]? {
        let round = asked.withLock { asked in
            defer { asked.append(challenge) }
            return asked.reduce(0) { $0 + $1.prompts.count }
        }
        return answers.dropFirst(round).prefix(challenge.prompts.count).map { Secret(utf8: $0) }
    }
}
