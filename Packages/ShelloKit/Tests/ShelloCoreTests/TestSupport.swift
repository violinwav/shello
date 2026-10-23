import CryptoKit
import Foundation
import LocalAuthentication
import Network
import ShelloModel
import ShelloSecurity
import ShelloStorage
import Synchronization
import Testing

@testable import ShelloCore

/// The OpenSSH server of TestServers/README.md on localhost port 2222, as in ShelloSSHTests: the
/// Docker server's user `shello` with its password, or this Mac's own sshd, keys only, as the user
/// `SHELLO_TEST_SERVER_USER` names. Both serve host key a.
enum TestServer {
    static let address = "localhost"
    static let port: UInt16 = 2222
    static let server = Server(address: address, port: port)

    private static let localUser = ProcessInfo.processInfo.environment["SHELLO_TEST_SERVER_USER"]
        .flatMap { $0.isEmpty ? nil : $0 }
    static let user = localUser ?? "shello"
    /// The user's password, or nil on a server that takes keys only.
    static let password: String? = localUser == nil ? "shello-test-password" : nil

    static let notRunning: Comment =
        "The test server is not running on localhost:2222. Start it with TestServers/ssh-server.sh (TestServers/README.md)."
    static let noPasswords: Comment = "The test server takes keys only."

    /// OpenSSH 8.8 on Alpine 3.15, in Docker only, with the same users.
    static let openSSH8Port: UInt16 = 2225
    static let openSSH8NotRunning: Comment =
        "The OpenSSH 8.8 test server is not running on localhost:2225. Start it with TestServers/ssh-server.sh (TestServers/README.md)."

    static var isOpenSSH8Running: Bool {
        get async { await openSSH8Probe.value }
    }

    private static let openSSH8Probe = Task { await hasSSHBanner(port: openSSH8Port) }

    /// The server with post-quantum key exchange off: in Docker, a container of its own, and with
    /// this Mac's sshd, one whose home directory is the servers' own (TestServers/local-sshd.sh). The
    /// tests that install SSH keys use it, since they write to `~/.ssh/authorized_keys`, which on
    /// port 2222 of this Mac's sshd is the user's own.
    static let installPort: UInt16 = 2224
    static let installServerNotRunning: Comment =
        "The test server is not running on localhost:2224. Start it with TestServers/ssh-server.sh (TestServers/README.md)."

    static var isInstallServerRunning: Bool {
        get async { await installProbe.value }
    }

    private static let installProbe = Task { await hasSSHBanner(port: installPort) }

    /// TestServers/keys/ssh_host_ed25519_key_a.pub.
    static let hostKeyA = HostKey(
        algorithm: "ssh-ed25519",
        wireRepresentation: Data(
            base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIHgTJMsflS9c2SZNLqrNUxilEPdrI1trFCrvwBsv0BQ9")!,
        fingerprint: "SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY")

    /// TestServers/keys/client_ed25519, which the servers let the test user in with: its private
    /// key's 32 bytes, as `ssh-keygen` wrote them into the file. A public test fixture.
    static let clientKey = SSHKeyStore.FixtureKey(
        privateKey: Data(base64Encoded: "ofQMdaZY6428Z0L+p1ROfYPD5L/UDl+PviWmLJf/bNY=")!, comment: "shello-test-client")

    /// TestServers/keys/ssh_host_ed25519_key_b.pub.
    static let hostKeyB = HostKey(
        algorithm: "ssh-ed25519",
        wireRepresentation: Data(
            base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIIJJGCfEG93QAyNvR5/qMneE615D5dVdNz8eF8nfUV2G")!,
        fingerprint: "SHA256:vRTlNPuThVvvrnjbeKgZ/H5Ud52Nq2MKVToLDK4pofI")

    /// Whether an SSH server greets on the port within two seconds.
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
}

/// A connector on a database of its own in a temporary directory, secrets and SSH keys in memory,
/// with the unlock window open, and a LocalAuthentication that answers at once. The key store holds
/// the test server's client key.
final class TestConnector: Sendable {
    let connector: HostConnector
    let hostKeys: HostKeyRepository
    /// The hosts, in the same database, where tabs record their connections.
    let hosts: HostRepository
    let keychain = CountingKeychain()
    let unlockWindow = UnlockWindow()
    let authentication = TestAuthentication()
    let keys: SSHKeyStore
    private let directory = URL.temporaryDirectory.appending(path: "ShelloCoreTests-\(UUID().uuidString)")

    /// A connector whose key store holds the client key, signing as `clientKeyPolicy` says. Keys that
    /// sign on every use ask `faceID`, if given, whose prompts wait; or else `authentication`.
    init(clientKeyPolicy: SigningPolicy = .whileUnlocked, faceID: PendingAuthentication? = nil) throws {
        let database = try AppDatabase(directory: directory)
        hostKeys = HostKeyRepository(database)
        hosts = HostRepository(database)
        unlockWindow.openWithoutAuthentication()
        let clientKey = SSHKeyStore.FixtureKey(
            privateKey: TestServer.clientKey.privateKey, comment: TestServer.clientKey.comment,
            signingPolicy: clientKeyPolicy)
        if let faceID {
            keys = .inMemory(unlockWindow: unlockWindow, authentication: faceID, fixtureKeys: [clientKey])
        } else {
            keys = .inMemory(unlockWindow: unlockWindow, authentication: authentication, fixtureKeys: [clientKey])
        }
        connector = HostConnector(
            hostKeys: hostKeys, secrets: SecretStore(keychain: keychain, unlockWindow: unlockWindow), keys: keys,
            authentication: authentication)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A password host for the test server, with `password` saved for it. It waits up to 30 seconds
    /// for the server: a CI runner's simulator once stalled Network.framework for about five seconds
    /// at a time, as ShelloSSHTests' TestServer says.
    func host(password: String?, port: UInt16 = TestServer.port, user: String = TestServer.user) throws -> Host {
        let host = Host(
            name: "test server", address: TestServer.address, port: port, username: user, authMethod: .password,
            connectTimeout: .seconds(30))
        if let password {
            keychain.store(Secret(utf8: password), as: .password(of: host.id))
        }
        return host
    }

    /// A host for the test server that signs in with its client key, through the SSH agent.
    func keyHost(port: UInt16 = TestServer.port, user: String = TestServer.user) throws -> Host {
        var host = try host(password: nil, port: port, user: user)
        host.authMethod = .sshKey
        host.sshKeyID = try clientKey().id
        return host
    }

    /// The test server's client key, in the key store, among any others a test made.
    func clientKey() throws -> SSHKey {
        try #require(try keys.keys().first { $0.comment == TestServer.clientKey.comment })
    }
}

/// LocalAuthentication's stand-in: every prompt is answered at once, as the test says, and counted.
final class TestAuthentication: Authentication {
    private struct State {
        var reasons: [String] = []
        var answer: Result<Void, UnlockError> = .success(())
        var capability = AuthenticationCapability.available(.faceID)
    }

    private let state = Mutex(State())

    /// How the next prompts end.
    func answer(_ answer: Result<Void, UnlockError>) {
        state.withLock { $0.answer = answer }
    }

    func setCapability(_ capability: AuthenticationCapability) {
        state.withLock { $0.capability = capability }
    }

    /// Why the user was asked to authenticate, each time.
    var reasons: [String] { state.withLock { $0.reasons } }

    func makeContext() -> sending LAContext {
        LAContext()
    }

    func capability(of context: LAContext) -> AuthenticationCapability {
        state.withLock { $0.capability }
    }

    func authenticate(_ context: LAContext, reason: String) async throws(UnlockError) {
        let answer = state.withLock { state in
            state.reasons.append(reason)
            return state.answer
        }
        try answer.get()
    }

    func invalidate(_ context: LAContext) {}
}

/// Secrets in memory that count how often a secret is read.
final class CountingKeychain: Keychain {
    private let memory = MemoryKeychain()
    private let readCount = Mutex(0)

    var reads: Int { readCount.withLock { $0 } }

    func store(_ secret: Secret, as id: SecretID) {
        memory.store(secret, as: id)
    }

    func secret(_ id: SecretID, context: LAContext) -> Secret? {
        readCount.withLock { $0 += 1 }
        return memory.secret(id, context: context)
    }

    func contains(_ id: SecretID, context: LAContext) -> Bool {
        memory.contains(id, context: context)
    }

    func remove(_ id: SecretID) {
        memory.remove(id)
    }
}

/// What the connector asked the user, and the answer it gets.
final class TrustQuestions: Sendable {
    private let asked = Mutex<[HostKey]>([])
    private let answer: Bool

    init(answer: Bool) {
        self.answer = answer
    }

    var keys: [HostKey] { asked.withLock { $0 } }

    func ask(_ server: Server, _ key: HostKey) -> Bool {
        asked.withLock { $0.append(key) }
        return answer
    }
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

/// The one-time codes of the Docker test servers' users `shello-otp` and `shello-2fa`
/// (TestServers/openssh/google_authenticator): TOTP (RFC 6238), six digits, a new one every 30
/// seconds, from the fixture secret `SHELLOTESTSECRET`. SHA-1 is TOTP's, not SSH's.
enum OneTimeCode {
    /// SHELLOTESTSECRET, decoded from base32.
    private static let secret = SymmetricKey(data: [145, 200, 181, 186, 100, 148, 228, 65, 68, 147] as [UInt8])

    /// The code at `date`.
    static func current(at date: Date = .now) -> String {
        let step = UInt64(date.timeIntervalSince1970 / 30)
        let counter = Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: step >> ($0 * 8)) })
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: counter, using: secret))
        let offset = Int(mac[19] & 0x0f)
        let number = mac[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & 0x7fff_ffff
        let digits = String(number % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }
}
