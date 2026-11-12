import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloTmux
import Synchronization
import Testing

@testable import ShelloCore

/// The command that installs an SSH key on a host (README section 13), and what its output means.
/// KeyInstallTests runs it on the test servers.
struct AuthorizedKeysTests {
    /// The command every login shell passes on to sh as it is: one line, two single quotes around the
    /// script, and nothing csh's history or fish's quoting would read anything into.
    @Test func commandIsOneLineThatEveryShellPassesOn() async throws {
        let keys = try TestKeys()
        let key = try await keys.make(#"it's "mine" $HOME `id` \ % ! ü"#)
        let channels = RecordingChannels(output: "shello-key-added\n")

        _ = try await AuthorizedKeys.install(key, on: channels)

        let command = try #require(channels.commands.first)
        #expect(command.hasPrefix("exec sh -c '"))
        #expect(command.hasSuffix("'"))
        let quotes = command.count { $0 == "'" }
        #expect(quotes == 2)
        let hasLineBreak = command.contains(where: \.isNewline)
        #expect(!hasLineBreak)
        #expect(!command.contains("!"))
        #expect(command.contains(key.publicKey.wireRepresentation.base64EncodedString()))
        // The name reaches the command only as octal escapes.
        #expect(!command.contains(#""mine""#) && !command.contains("$HOME") && !command.contains("`id`"))
        #expect(command.contains(#"it\047s \042mine\042 \044HOME \140id\140 \134 %% \041 \303\274"#))
    }

    @Test func printfFormatEscapesWhatAShellOrPrintfWouldRead() {
        #expect(
            AuthorizedKeys.printfFormat("ssh-ed25519 AAAA+/= user@host:22,x_y.z")
                == "ssh-ed25519 AAAA+/= user@host:22,x_y.z")
        #expect(AuthorizedKeys.printfFormat("100%") == "100%%")
        #expect(AuthorizedKeys.printfFormat("a'b\"c$d`e\\f!g*h") == #"a\047b\042c\044d\140e\134f\041g\052h"#)
        #expect(AuthorizedKeys.printfFormat("é") == #"\303\251"#)
    }

    /// The marker on the last line says what happened; whatever the login shell printed before it
    /// does not matter.
    @Test func outputSaysWhetherTheKeyWasAddedOrThereAlready() throws {
        let added = SSHCommandResult(output: Array("shello-key-added\n".utf8), errorOutput: [], exitStatus: 0)
        let present = SSHCommandResult(
            output: Array("Welcome to the server\nshello-key-present\n".utf8), errorOutput: [], exitStatus: 0)

        #expect(try AuthorizedKeys.installation(from: added) == .added)
        #expect(try AuthorizedKeys.installation(from: present) == .alreadyInstalled)
    }

    /// A command that failed, or ended without saying, is an error that says what the server said,
    /// as the screen can show it.
    @Test func failureSaysWhatTheServerSaid() {
        let denied = SSHCommandResult(
            output: [],
            errorOutput: Array("\n  mkdir: can't create directory '.ssh':\u{202E} Permission denied\n".utf8),
            exitStatus: 1)
        let silent = SSHCommandResult(output: Array("no marker\n".utf8), errorOutput: [], exitStatus: 0)
        let signalled = SSHCommandResult(output: [], errorOutput: [], exitStatus: nil)

        #expect(
            throws: KeyInstallationError.commandFailed(
                exitStatus: 1, "mkdir: can't create directory '.ssh': Permission denied")
        ) {
            try AuthorizedKeys.installation(from: denied)
        }
        #expect(throws: KeyInstallationError.commandFailed(exitStatus: 0, "no marker")) {
            try AuthorizedKeys.installation(from: silent)
        }
        #expect(throws: KeyInstallationError.commandFailed(exitStatus: nil, "The command ended without a status.")) {
            try AuthorizedKeys.installation(from: signalled)
        }
        let long = SSHCommandResult(
            output: [], errorOutput: Array(String(repeating: "x", count: 500).utf8), exitStatus: 2)
        #expect(AuthorizedKeys.detail(of: long).count == AuthorizedKeys.maximumDetailLength)
    }

    /// A connection that is gone is the connection's error, not the command's.
    @Test func connectionThatIsGoneFailsWithItsError() async throws {
        let key = try await TestKeys().make("a")
        let channels = RecordingChannels(error: SSHError.connectionLost("the network went away"))

        await #expect(throws: SSHError.connectionLost("the network went away")) {
            try await AuthorizedKeys.install(key, on: channels)
        }
    }
}

/// SSH keys in memory for the tests, behind an unlock window that is open.
private struct TestKeys {
    let window = UnlockWindow()
    let store: SSHKeyStore

    init() throws {
        window.openWithoutAuthentication()
        store = .inMemory(unlockWindow: window)
    }

    func make(_ comment: String) async throws -> SSHKey {
        try await store.generate(.ed25519, comment: comment, signingPolicy: .whileUnlocked)
    }
}

/// Hidden channels that record the commands they are given and answer each with `output`, or fail
/// with `error`.
private final class RecordingChannels: HiddenChannels {
    private let recorded = Mutex<[String]>([])
    private let output: String
    private let error: SSHError?

    init(output: String = "", error: SSHError? = nil) {
        self.output = output
        self.error = error
    }

    var commands: [String] { recorded.withLock { $0 } }

    func run(_ command: String) async throws -> SSHCommandResult {
        recorded.withLock { $0.append(command) }
        if let error { throw error }
        return SSHCommandResult(output: Array(output.utf8), errorOutput: [], exitStatus: 0)
    }
}
