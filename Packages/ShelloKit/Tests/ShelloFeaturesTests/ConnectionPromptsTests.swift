import Foundation
import ShelloCore
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloTerminalUI
import Testing

@testable import ShelloFeatures

/// What the screens ask around a connection: the Local Network explanation before the first
/// connection to a server on the local network (README section 3), and the sign-in sheet's questions
/// (README section 4). UI tests take both through the app.
struct ConnectionPromptsTests {
    let defaults: UserDefaults
    private let suite = "ConnectionPromptsTests-\(UUID().uuidString)"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    @Test @MainActor func localServerIsExplainedUntilTheUserContinues() {
        let notice = LocalNetworkNotice(defaults: defaults)
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")

        #expect(notice.explainsBeforeConnecting(to: nas))

        notice.markExplained()

        #expect(!notice.explainsBeforeConnecting(to: nas))
        // iOS asks once per install, so the explanation is not needed after a relaunch either.
        #expect(!LocalNetworkNotice(defaults: defaults).explainsBeforeConnecting(to: nas))
    }

    /// iOS does not ask about servers elsewhere, nor about this device's loopback.
    @Test(arguments: ["prod-api-01.example.com", "8.8.8.8", "localhost", "127.0.0.1"])
    @MainActor
    func otherServersAreNotExplained(_ address: String) {
        let notice = LocalNetworkNotice(defaults: defaults)

        #expect(!notice.explainsBeforeConnecting(to: Host(name: "host", address: address, username: "admin")))
    }

    /// A question's text is the field's label for VoiceOver, without the colon and space it ends with.
    @Test(arguments: [
        ("Password: ", "Password"), ("Verification code:", "Verification code"), ("Enter PIN", "Enter PIN"),
        (": ", "Answer"), ("Your password expired.\nNew password:", "Your password expired.\nNew password"),
    ])
    func questionIsReadWithoutItsColon(_ text: String, spoken: String) {
        #expect(KeyboardInteractivePrompt(text: text, showsAnswer: false).spokenText == spoken)
    }

    /// Cancelling the user's own Face ID says nothing; anything else says that the key stays.
    @Test func replacementProblemsSayTheKeyStays() {
        #expect(UnlockError.failed.replacementProblem.hasSuffix("The trusted host key stays."))
        #expect(UnlockError.other(code: -1000).replacementProblem.contains("-1000"))
    }
}

/// The terminal's model while it asks the server's keyboard-interactive questions, against the
/// Docker test server, whose sshd asks `shello` for its password. Skipped without it, as in CI.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct SignInPromptTests {
    let secrets = TestSecrets()
    let test: TestDatabase

    init() throws {
        test = try TestDatabase()
    }

    /// One sheet asks the questions and stays until signing in ends; the answers sign in.
    @Test(.enabled(Self.notRunning) { await Self.serverAsksQuestions })
    func signInSheetAsksAndSignsIn() async throws {
        let model = try await Self.model(test: test, secrets: secrets)

        model.start()
        await waitUntil { model.signInQuestion != nil || model.phase != .connecting }

        #expect(model.prompt == .signIn)
        let question = try #require(model.signInQuestion)
        #expect(question.challenge.prompts.map(\.text) == ["Password:"])
        model.answerSignIn([Secret(utf8: "shello-test-password")])
        #expect(model.prompt == .signIn)
        await waitUntil { model.phase != .connecting }
        #expect(model.phase == .attached)
        #expect(model.prompt == nil)
        model.close()
    }

    /// Cancelling the questions closes the screen, as declining a host key does.
    @Test(.enabled(Self.notRunning) { await Self.serverAsksQuestions })
    func cancellingTheQuestionsClosesTheScreen() async throws {
        let model = try await Self.model(test: test, secrets: secrets)

        model.start()
        await waitUntil { model.signInQuestion != nil || model.phase != .connecting }
        model.dismissPrompt()
        await waitUntil { model.phase != .connecting }

        #expect(model.phase == .stopped)
        #expect(model.prompt == nil)
    }

    /// A keyboard-interactive host for the Docker test server, whose host key is trusted.
    private static func model(test: TestDatabase, secrets: TestSecrets) async throws -> HostTerminalModel {
        let host = Host(
            name: "test server", address: "localhost", port: 2222, username: "shello",
            authMethod: .keyboardInteractive, connectTimeout: .seconds(30))
        let hostKeyA = HostKey(
            algorithm: "ssh-ed25519",
            wireRepresentation: Data(
                base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIHgTJMsflS9c2SZNLqrNUxilEPdrI1trFCrvwBsv0BQ9")!,
            fingerprint: "SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY")
        try await test.hostKeys.trust(hostKeyA, of: host.server)
        let connector = HostConnector(hostKeys: test.hostKeys, secrets: secrets.store)
        return HostTerminalModel(host: host, connector: connector, controller: TerminalController())
    }

    static let notRunning: Comment =
        "The Docker test server is not running on localhost:2222. Start it with TestServers/ssh-server.sh (TestServers/README.md)."

    /// Whether the Docker test server answers on localhost:2222 and asks for a password: CI's sshd
    /// takes keys only, as the user `SHELLO_TEST_SERVER_USER` names.
    static var serverAsksQuestions: Bool {
        get async {
            guard ProcessInfo.processInfo.environment["SHELLO_TEST_SERVER_USER"].map(\.isEmpty) ?? true else {
                return false
            }
            let connection = SSHConnection(
                server: Server(address: "localhost", port: 2222), username: "shello", connectTimeout: .seconds(5))
            defer { Task { await connection.close() } }
            return (try? await connection.connect()) != nil
        }
    }
}
