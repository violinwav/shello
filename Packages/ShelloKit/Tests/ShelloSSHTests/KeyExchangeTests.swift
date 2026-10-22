import ShelloModel
import Testing

@testable import ShelloSSH

/// The key exchange Shello's algorithm policy gets from servers of different ages (spike item 4 of
/// README section 18), as libssh reports it, with the banner each server greets with. The tests only
/// connect: no one signs in. Each skips when its test server (TestServers/README.md) is not running.
/// In Docker all three run; CI runs this Mac's own sshd, OpenSSH 10, on ports 2222 and 2224 only,
/// so the OpenSSH 9 tests skip there.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct KeyExchangeTests {
    @Test(.enabled(TestServer.notRunning) { await TestServer.isRunning })
    func openSSH10NegotiatesMLKEM() async throws {
        let (banner, keyExchange) = try await Self.negotiate(with: TestServer.server)

        #expect(banner.hasPrefix("SSH-2.0-OpenSSH_10."))
        #expect(keyExchange == KeyExchange(name: "mlkem768x25519-sha256", isPostQuantum: true))
    }

    /// OpenSSH before 9.9 has no ML-KEM, and knows sntrup761x25519-sha512 by its older name only.
    @Test(.enabled(TestServer.openSSH9NotRunning) { await TestServer.isOpenSSH9Running })
    func openSSH9NegotiatesSNTRUP() async throws {
        let (banner, keyExchange) = try await Self.negotiate(with: TestServer.openSSH9)

        #expect(banner.hasPrefix("SSH-2.0-OpenSSH_9."))
        #expect(keyExchange == KeyExchange(name: "sntrup761x25519-sha512@openssh.com", isPostQuantum: true))
    }

    @Test(.enabled(TestServer.classicalNotRunning) { await TestServer.isClassicalRunning })
    func serverWithoutPostQuantumKeyExchangeNegotiatesCurve25519() async throws {
        let (banner, keyExchange) = try await Self.negotiate(with: TestServer.classical)

        #expect(banner.hasPrefix("SSH-2.0-OpenSSH_10."))
        #expect(keyExchange == KeyExchange(name: "curve25519-sha256", isPostQuantum: false))
    }

    /// Why the policy offers sntrup761x25519-sha512 under both names: offered only its standard
    /// name, OpenSSH 9 falls back to a classical key exchange.
    @Test(.enabled(TestServer.openSSH9NotRunning) { await TestServer.isOpenSSH9Running })
    func openSSH9DoesNotKnowTheStandardNameOfSNTRUP() async throws {
        let policy = AlgorithmPolicy(
            version: 0, keyExchanges: ["mlkem768x25519-sha256", "sntrup761x25519-sha512", "curve25519-sha256"],
            postQuantumKeyExchanges: AlgorithmPolicy.standard.postQuantumKeyExchanges)

        let (_, keyExchange) = try await Self.negotiate(with: TestServer.openSSH9, algorithms: policy)

        #expect(keyExchange == KeyExchange(name: "curve25519-sha256", isPostQuantum: false))
    }

    /// Shello's order decides, not the server's: offered curve25519-sha256 first, OpenSSH 10 takes it.
    @Test(.enabled(TestServer.notRunning) { await TestServer.isRunning })
    func thePolicysOrderDecides() async throws {
        let policy = AlgorithmPolicy(
            version: 0, keyExchanges: ["curve25519-sha256", "mlkem768x25519-sha256"],
            postQuantumKeyExchanges: AlgorithmPolicy.standard.postQuantumKeyExchanges)

        let (_, keyExchange) = try await Self.negotiate(with: TestServer.server, algorithms: policy)

        #expect(keyExchange == KeyExchange(name: "curve25519-sha256", isPostQuantum: false))
    }

    /// Connects to `server` offering `algorithms`, and returns how the server greeted and the key
    /// exchange libssh negotiated. Both are printed, for the spike's report.
    private static func negotiate(
        with server: Server, algorithms: AlgorithmPolicy = .standard
    ) async throws -> (banner: String, keyExchange: KeyExchange?) {
        let connection = SSHConnection(
            server: server, username: TestServer.user, connectTimeout: TestServer.connectTimeout,
            algorithms: algorithms)
        _ = try await connection.connect()
        let banner = await connection.serverBanner ?? ""
        let keyExchange = await connection.keyExchange
        await connection.close()
        print(
            "\(server) greets with \(banner); offered \(algorithms.keyExchanges.joined(separator: ",")), "
                + "libssh negotiated \(keyExchange?.name ?? "nothing")")
        return (banner, keyExchange)
    }
}

extension TestServer {
    /// OpenSSH 9.6 on Ubuntu 24.04, in Docker only.
    static let openSSH9 = Server(address: address, port: 2223)
    /// OpenSSH 10 with post-quantum key exchange off: in Docker, or this Mac's own sshd.
    static let classical = Server(address: address, port: 2224)

    static var isOpenSSH9Running: Bool {
        get async { await openSSH9Probe.value }
    }

    static var isClassicalRunning: Bool {
        get async { await classicalProbe.value }
    }

    private static let openSSH9Probe = Task { await hasSSHBanner(port: openSSH9.port) }
    private static let classicalProbe = Task { await hasSSHBanner(port: classical.port) }

    static let openSSH9NotRunning: Comment =
        "The OpenSSH 9 test server is not running on localhost:2223. Start it with TestServers/ssh-server.sh (TestServers/README.md)."
    static let classicalNotRunning: Comment =
        "The test server without post-quantum key exchange is not running on localhost:2224. Start it with TestServers/ssh-server.sh (TestServers/README.md)."
}
