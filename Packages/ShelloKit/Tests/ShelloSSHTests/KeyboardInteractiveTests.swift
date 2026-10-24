import Foundation
import ShelloModel
import Synchronization
import Testing

@testable import ShelloSSH

/// Keyboard-interactive sign-in (RFC 4256, README section 4) against the Docker test servers, whose
/// sshd asks through PAM: `shello` its password, one question that hides the answer. CI's sshd cannot
/// ask anything, so these tests skip there, as the password tests do. ShelloCoreTests answer the
/// one-time codes of `shello-otp` and `shello-2fa`.
@Suite(
    .serialized, .enabled(TestServer.notRunning) { await TestServer.isRunning },
    .enabled(if: TestServer.password != nil, TestServer.noPasswords), .timeLimit(.minutes(1)))
struct KeyboardInteractiveTests {
    @Test func signsInByAnsweringThePasswordQuestion() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()
        let questions = Questions(answers: [TestServer.password ?? ""])

        try await connection.authenticate(keyboardInteractive: questions.answer)

        #expect(questions.asked.count == 1)
        let prompt = try #require(questions.asked.first?.prompts.first)
        #expect(prompt.text == "Password:")
        #expect(!prompt.showsAnswer)
        #expect(try await connection.run("whoami").outputText == "\(TestServer.user)\n")
        await connection.close()
    }

    /// The oldest OpenSSH Shello supports asks the same way.
    @Test(.enabled(TestServer.openSSH8NotRunning) { await TestServer.isOpenSSH8Running })
    func openSSH88AsksThePasswordQuestionToo() async throws {
        let connection = SSHConnection(
            server: TestServer.openSSH8, username: TestServer.user, connectTimeout: TestServer.connectTimeout)
        _ = try await connection.connect()
        let questions = Questions(answers: [TestServer.password ?? ""])

        try await connection.authenticate(keyboardInteractive: questions.answer)

        #expect(questions.asked.first?.prompts.map(\.text) == ["Password:"])
        #expect(try await connection.run("whoami").outputText == "\(TestServer.user)\n")
        await connection.close()
    }

    @Test func wrongAnswerIsRefused() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()
        let questions = Questions(answers: ["not-the-password"])

        await #expect(throws: SSHError.authenticationFailed) {
            try await connection.authenticate(keyboardInteractive: questions.answer)
        }
        await connection.close()
    }

    /// Each question gets an answer, no more and no fewer.
    @Test func answersThatDoNotMatchTheQuestionsAreRefused() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()
        let questions = Questions(answers: ["one", "two"])

        await #expect(throws: SSHError.protocolError("2 answers to 1 questions")) {
            try await connection.authenticate(keyboardInteractive: questions.answer)
        }
        await connection.close()
    }

    /// A user who cancels the questions ends the sign-in with what the answering throws.
    @Test func answeringThatThrowsEndsTheSignIn() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()

        await #expect(throws: CancellationError.self) {
            try await connection.authenticate(keyboardInteractive: { _ in throw CancellationError() })
        }
        await connection.close()
    }

    /// A server that signs in with a key, then a one-time code, says so after the key.
    @Test func twoFactorServerAsksForKeyboardInteractiveAfterTheKey() async throws {
        let connection = SSHConnection(
            server: TestServer.server, username: "shello-2fa", connectTimeout: TestServer.connectTimeout)
        _ = try await connection.connect()

        await #expect(throws: SSHError.partiallyAuthenticated(.keyboardInteractive)) {
            try await connection.authenticate(privateKey: TestSecret(TestServer.clientKey))
        }
        await connection.close()
    }
}

/// What a server's questions look like once Shello has read them: untrusted text without the
/// characters that could disguise it.
struct KeyboardInteractiveChallengeTests {
    @Test func textKeepsLineBreaksAndLosesControlCharacters() {
        let prompt = KeyboardInteractivePrompt(text: "Pass\u{1B}[31mword\u{7}:\r\nnext\tline\u{0}", showsAnswer: false)

        #expect(prompt.text == "Pass[31mword:\nnext\tline")
    }

    /// Bidirectional overrides could make "Code:" read backwards, or reorder a warning.
    @Test func textLosesBidirectionalOverrides() {
        let challenge = KeyboardInteractiveChallenge(
            name: "\u{202E}edoC", instruction: "Type \u{2066}it\u{2069} here", prompts: [])

        #expect(challenge.name == "edoC")
        #expect(challenge.instruction == "Type it here")
    }

    @Test func textLosesSurroundingWhitespace() {
        let challenge = KeyboardInteractiveChallenge(
            name: "  Two-factor sign-in\n", instruction: "\n", prompts: [])

        #expect(challenge.name == "Two-factor sign-in")
        #expect(challenge.instruction.isEmpty)
    }

    @Test func longTextIsCut() {
        let prompt = KeyboardInteractivePrompt(text: String(repeating: "a", count: 5000), showsAnswer: true)

        #expect(prompt.text.count == KeyboardInteractiveChallenge.maximumTextLength)
    }
}

/// The answers a test gives, and the questions it was asked.
final class Questions: Sendable {
    private let answers: [String]
    private let recorded = Mutex<[KeyboardInteractiveChallenge]>([])

    init(answers: [String]) {
        self.answers = answers
    }

    var asked: [KeyboardInteractiveChallenge] { recorded.withLock { $0 } }

    func answer(_ challenge: KeyboardInteractiveChallenge) -> [any SecretBytes] {
        recorded.withLock { $0.append(challenge) }
        return answers.map(TestSecret.init)
    }
}
