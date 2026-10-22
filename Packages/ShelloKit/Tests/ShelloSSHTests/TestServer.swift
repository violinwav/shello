import Foundation
import Network
import ShelloModel
import Synchronization
import Testing

@testable import ShelloSSH

/// The OpenSSH server the integration tests sign in to, on localhost port 2222, which
/// TestServers/README.md starts with one command:
/// - In Docker (`TestServers/ssh-server.sh`): user `shello`, with its password or the fixture key.
/// - This Mac's own sshd (`TestServers/local-sshd.sh`), as in CI, whose macOS runners have no
///   Docker: the user it runs as, with the fixture key only, since an unprivileged sshd cannot check
///   passwords. `SHELLO_TEST_SERVER_USER` names that user; xcodebuild passes it on from
///   `TEST_RUNNER_SHELLO_TEST_SERVER_USER`.
///
/// Both serve host key a. Every credential here is a test fixture, public in TestServers/keys.
enum TestServer {
    static let address = "localhost"
    static let port: UInt16 = 2222
    static let server = Server(address: address, port: port)

    private static let localUser = ProcessInfo.processInfo.environment["SHELLO_TEST_SERVER_USER"]
        .flatMap { $0.isEmpty ? nil : $0 }
    static let user = localUser ?? "shello"
    /// The user's password, or nil on a server that takes keys only.
    static let password: String? = localUser == nil ? "shello-test-password" : nil

    /// Why the tests that need the server are skipped when it is not running.
    static let notRunning: Comment =
        "The test server is not running on localhost:2222. Start it with TestServers/ssh-server.sh (TestServers/README.md)."
    static let noPasswords: Comment = "The test server takes keys only."

    /// A new connection to the server as the test user.
    static func connection(connectTimeout: Duration = .seconds(10)) -> SSHConnection {
        SSHConnection(server: server, username: user, connectTimeout: connectTimeout)
    }

    /// A connection to the server, signed in with the fixture key.
    static func signedInConnection() async throws -> SSHConnection {
        let connection = connection()
        _ = try await connection.connect()
        try await connection.authenticate(privateKey: TestSecret(clientKey))
        return connection
    }

    /// Whether an SSH server answers on the port: it greets with its banner within two seconds. The
    /// probe uses Network.framework directly, so that a broken `SSHConnection` fails the tests
    /// rather than skipping them.
    static var isRunning: Bool {
        get async { await probe.value }
    }

    private static let probe = Task { await hasSSHBanner(port: port) }

    /// Whether an SSH server greets on `port` of this device within two seconds.
    static func hasSSHBanner(port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "ch.shello.tests.probe")
            let connection = NWConnection(
                host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { isSSH in
                guard once.isFirst() else { return }
                connection.cancel()
                continuation.resume(returning: isSSH)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 8, maximumLength: 256) { data, _, _, _ in
                        finish(data.map { String(decoding: $0, as: UTF8.self).hasPrefix("SSH-2.0-") } ?? false)
                    }
                case .waiting, .failed: finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 2) { finish(false) }
            connection.start(queue: queue)
        }
    }

    // MARK: - Fixtures

    /// TestServers/keys/ssh_host_ed25519_key_a.pub, which both servers present.
    static let hostKeyA = HostKey(
        algorithm: "ssh-ed25519",
        wireRepresentation: Data(
            base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIHgTJMsflS9c2SZNLqrNUxilEPdrI1trFCrvwBsv0BQ9")!,
        fingerprint: "SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY")

    /// TestServers/keys/ssh_host_ed25519_key_b.pub, which `ssh-server.sh --host-key b` presents.
    static let hostKeyB = HostKey(
        algorithm: "ssh-ed25519",
        wireRepresentation: Data(
            base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIIJJGCfEG93QAyNvR5/qMneE615D5dVdNz8eF8nfUV2G")!,
        fingerprint: "SHA256:vRTlNPuThVvvrnjbeKgZ/H5Ud52Nq2MKVToLDK4pofI")

    /// TestServers/keys/client_ed25519: the key the servers let the test user in with.
    static let clientKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACC5AfFMjEPBTTvZotrhJFpFa1+Y3NJdZB6geFTJ7J7MOQAAAJjjp44F46eO
        BQAAAAtzc2gtZWQyNTUxOQAAACC5AfFMjEPBTTvZotrhJFpFa1+Y3NJdZB6geFTJ7J7MOQ
        AAAECh9Ax1pljrjbxnQv6nVE59g8Pkv9QOX4++JaYsl/9s1rkB8UyMQ8FNO9mi2uEkWkVr
        X5jc0l1kHqB4VMnsnsw5AAAAEnNoZWxsby10ZXN0LWNsaWVudAECAw==
        -----END OPENSSH PRIVATE KEY-----

        """

    /// TestServers/keys/client_ed25519_encrypted: the same key, encrypted with `passphrase`.
    static let encryptedClientKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABD0m+hHZ8
        9oyUXsjpIkvuqIAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAILkB8UyMQ8FNO9mi
        2uEkWkVrX5jc0l1kHqB4VMnsnsw5AAAAoOE8PS5b7XvkQgBYtAGEECKN6xU4sSPggcBLzm
        GJp/hNnHswei5pBQmmwAKS3enAJ81YPbwVNVTAQgFpEbsmt5NnfDkF05ggWAuEMQIjam1c
        8GCtS2+JN/xx9KQdqJAmj5ed9DhoNtw29Q9bNgT8pZqZMMJkcqXLrjATAq2u2V/YXMnJYO
        OgzbcnB929TZ/ukaG43AHLJVn5hH6TrQHdnvw=
        -----END OPENSSH PRIVATE KEY-----

        """

    static let passphrase = "shello-test-passphrase"
}

/// Says yes once, to the first caller.
final class Once: Sendable {
    private let done = Mutex(false)

    func isFirst() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}

/// A secret for the tests: its bytes, then a zero byte, as `SecretBytes` promises.
final class TestSecret: SecretBytes {
    private let bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8) + [0]
    }

    func withUnsafeBytes<Result, Failure: Error>(
        _ body: (UnsafeRawBufferPointer) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let result: Swift.Result<Result, Failure> = unsafe bytes.withUnsafeBytes { buffer in
            do throws(Failure) {
                return .success(try unsafe body(UnsafeRawBufferPointer(rebasing: buffer.dropLast())))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }
}

extension SSHShell {
    /// Reads the shell's output until it contains `text`, and returns all of it. After `timeout`
    /// the read is cancelled, which ends the output, and the test records an issue.
    func output(containing text: String, within timeout: Duration = .seconds(15)) async throws -> String {
        let reader = Task {
            var output = ""
            for try await chunk in self.output {
                output += String(decoding: chunk, as: UTF8.self)
                if output.contains(text) { break }
            }
            return output
        }
        let timer = Task {
            try await Task.sleep(for: timeout)
            reader.cancel()
        }
        defer { timer.cancel() }
        let output = try await reader.value
        if !output.contains(text) {
            Issue.record("The shell's output does not contain \(text): \(output)")
        }
        return output
    }
}
