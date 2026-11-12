import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import Testing

@testable import ShelloCore

/// Installing an SSH key on a host (README section 13), over a hidden channel of a connection signed
/// in with the client key, as `ssh-copy-id` does: the key is added once, then found there, and signs in
/// from then on. In a home of the test's own, `~/.ssh` and the file are made with their modes, a file
/// without a final line break gets one, and a comment of any characters reaches the file as it is.
///
/// On the test server on port 2224: its `~` is a container's in Docker, and with this Mac's sshd the
/// servers' own home directory, never the user's (TestServers/local-sshd.sh). Each key installed is
/// new, and taken out again.
@Suite(
    .serialized, .enabled(TestServer.installServerNotRunning) { await TestServer.isInstallServerRunning },
    .timeLimit(.minutes(1)))
struct KeyInstallTests {
    let test: TestConnector

    init() throws {
        test = try TestConnector()
    }

    @Test func installsTheKeyOnceAndItSignsInAfterwards() async throws {
        let key = try await test.keys.generate(
            .ed25519, comment: "shello-install-test-\(UUID().uuidString)", signingPolicy: .whileUnlocked)
        let blob = key.publicKey.wireRepresentation.base64EncodedString()
        let connection = try await signedInConnection()
        defer { Task { await connection.close() } }

        #expect(try await AuthorizedKeys.install(key, on: connection) == .added)
        #expect(try await AuthorizedKeys.install(key, on: connection) == .alreadyInstalled)

        let lines = try await connection.run("cat ~/.ssh/authorized_keys")
        #expect(
            String(decoding: lines.output, as: UTF8.self).split(separator: "\n").filter { $0.contains(blob) } == [
                Substring(key.openSSHPublicKey)
            ])

        var host = try test.keyHost(port: TestServer.installPort)
        host.sshKeyID = key.id
        let signedInWithTheKey = try await test.connector.connect(to: host) { _, _ in false }
        let whoami = try await signedInWithTheKey.run("whoami")
        #expect(String(decoding: whoami.output, as: UTF8.self) == "\(TestServer.user)\n")
        await signedInWithTheKey.close()

        // grep finds no other line on a server whose file had none: that is no failure.
        let removed = try await connection.run(
            "umask 077 && { grep -v -F -e \(blob) ~/.ssh/authorized_keys || :; } > ~/.ssh/shello-test && "
                + "mv ~/.ssh/shello-test ~/.ssh/authorized_keys")
        #expect(removed.exitStatus == 0)
    }

    /// A home without `~/.ssh`: both are made, readable by their owner only, and the file holds the
    /// key's line alone.
    @Test func makesTheDirectoryAndTheFileWithTheirModes() async throws {
        let key = try await test.keys.generate(.ed25519, comment: "fresh home", signingPolicy: .whileUnlocked)
        let connection = try await signedInConnection()
        defer { Task { await connection.close() } }
        let home = try await temporaryHome(on: connection)

        let result = try await install(key, home: home, on: connection)

        #expect(try AuthorizedKeys.installation(from: result) == .added)
        let modes = try await connection.run("ls -ld \(home)/.ssh \(home)/.ssh/authorized_keys")
        let lines = String(decoding: modes.output, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("drwx------") == true, "\(lines)")
        #expect(lines.last?.hasPrefix("-rw-------") == true, "\(lines)")
        #expect(try await contents(of: "\(home)/.ssh/authorized_keys", on: connection) == key.openSSHPublicKey + "\n")
        _ = try await connection.run("rm -rf \(home)")
    }

    /// The file's own lines stay as they are: one without a final line break gets one before the
    /// key, a copy of the key that is a comment does not count, and the key with options and another
    /// comment does. The key's name reaches the file byte for byte, whatever a shell would read in it.
    @Test func keepsTheFilesLinesAndWritesTheCommentAsItIs() async throws {
        let comment = #"it's "work" $HOME `id` \n %s %% ! * ; | & ünïcødé 🔑"#
        let key = try await test.keys.generate(.ed25519, comment: comment, signingPolicy: .whileUnlocked)
        let other = try await test.keys.generate(.ed25519, comment: "other", signingPolicy: .whileUnlocked)
        let blob = key.publicKey.wireRepresentation.base64EncodedString()
        let connection = try await signedInConnection()
        defer { Task { await connection.close() } }
        let home = try await temporaryHome(on: connection)
        let file = "\(home)/.ssh/authorized_keys"
        let existing = "# ssh-ed25519 \(blob) revoked\n\(other.openSSHPublicKey)"
        let written = try await connection.run(
            "mkdir -m 700 \(home)/.ssh && printf '%s' '\(existing)' > \(file) && chmod 640 \(file)")
        #expect(written.exitStatus == 0)

        #expect(try AuthorizedKeys.installation(from: try await install(key, home: home, on: connection)) == .added)

        #expect(try await contents(of: file, on: connection) == existing + "\n" + key.openSSHPublicKey + "\n")
        // The file's mode stays the user's.
        let mode = try await connection.run("ls -l \(file)")
        #expect(String(decoding: mode.output, as: UTF8.self).hasPrefix("-rw-r-----"))

        let withOptions = "no-agent-forwarding,from=\"127.0.0.1\" ssh-ed25519 \(blob) laptop"
        _ = try await connection.run("printf '%s\\n' '\(withOptions)' > \(file)")
        #expect(
            try AuthorizedKeys.installation(from: try await install(key, home: home, on: connection))
                == .alreadyInstalled)
        _ = try await connection.run("rm -rf \(home)")
    }

    /// A home the user cannot write to: the server's message says why.
    @Test func homeThatCannotBeWrittenFails() async throws {
        let key = try await test.keys.generate(.ed25519, comment: "read-only", signingPolicy: .whileUnlocked)
        let connection = try await signedInConnection()
        defer { Task { await connection.close() } }
        let home = try await temporaryHome(on: connection)
        _ = try await connection.run("chmod 500 \(home)")

        let result = try await install(key, home: home, on: connection)

        #expect(throws: KeyInstallationError.self) { try AuthorizedKeys.installation(from: result) }
        #expect(AuthorizedKeys.detail(of: result).localizedCaseInsensitiveContains("permission denied"))
        _ = try await connection.run("chmod 700 \(home) && rm -rf \(home)")
    }

    // MARK: - Helpers

    /// A connection to the install server, signed in with the client key.
    private func signedInConnection() async throws -> SSHConnection {
        let host = try test.keyHost(port: TestServer.installPort)
        try await test.hostKeys.trust(TestServer.hostKeyA, of: host.server)
        return try await test.connector.connect(to: host) { _, _ in false }
    }

    /// A new, empty home directory under the server's `/tmp`.
    private func temporaryHome(on connection: SSHConnection) async throws -> String {
        let home = "/tmp/shello-install-test-\(UUID().uuidString)"
        let made = try await connection.run("mkdir -m 755 \(home)")
        #expect(made.exitStatus == 0)
        return home
    }

    /// Runs the install command's script with `home` as the home directory, as the user's login shell
    /// passes it to sh.
    private func install(_ key: SSHKey, home: String, on connection: SSHConnection) async throws -> SSHCommandResult {
        let script = AuthorizedKeys.script(
            installing: key.openSSHPublicKey, blob: key.publicKey.wireRepresentation.base64EncodedString())
        return try await connection.run("env HOME=\(home) sh -c '\(script)'")
    }

    private func contents(of file: String, on connection: SSHConnection) async throws -> String {
        String(decoding: try await connection.run("cat \(file)").output, as: UTF8.self)
    }
}
