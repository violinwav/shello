import ShelloModel
import Testing

@testable import ShelloSSH

/// What Shello's algorithm policy negotiates with servers of different ages and settings (spike item
/// 4 of README section 18, README section 4), as libssh reports it, with the banner each server
/// greets with. The tests only connect: no one signs in. Each skips when its test server
/// (TestServers/README.md) is not running. In Docker all of them run; CI runs this Mac's own sshd,
/// OpenSSH 10, on ports 2222, 2224 and 2226 only, so the OpenSSH 9 and 8.8 tests skip there.
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

    /// The oldest OpenSSH Shello supports (README section 4). OpenSSH 8.8 has
    /// sntrup761x25519-sha512@openssh.com, but offers it only when configured to; OpenSSH 9.0 made
    /// it a default.
    @Test(.enabled(TestServer.openSSH8NotRunning) { await TestServer.isOpenSSH8Running })
    func openSSH88NegotiatesCurve25519() async throws {
        let (banner, keyExchange) = try await Self.negotiate(with: TestServer.openSSH8)

        #expect(banner.hasPrefix("SSH-2.0-OpenSSH_8.8"))
        #expect(keyExchange == KeyExchange(name: "curve25519-sha256", isPostQuantum: false))
    }

    /// A server without curve25519, as one in FIPS mode, still connects: the policy offers the NIST
    /// curves after it.
    @Test(.enabled(TestServer.nistNotRunning) { await TestServer.isNISTRunning })
    func serverWithoutCurve25519NegotiatesECDH() async throws {
        let (banner, keyExchange) = try await Self.negotiate(with: TestServer.nist)

        #expect(banner.hasPrefix("SSH-2.0-OpenSSH_"))
        #expect(keyExchange == KeyExchange(name: "ecdh-sha2-nistp256", isPostQuantum: false))
    }

    /// Each classical key exchange the policy offers after curve25519 works on its own, the
    /// Diffie-Hellman groups included: offered alone, the server without curve25519 takes it.
    @Test(
        .enabled(TestServer.nistNotRunning) { await TestServer.isNISTRunning },
        arguments: AlgorithmPolicy.standard.keyExchanges.drop { $0 != "curve25519-sha256" }.dropFirst())
    func classicalKeyExchangeWorksAlone(_ name: String) async throws {
        let policy = AlgorithmPolicy.standard.overridden(by: AlgorithmOverrides(keyExchanges: [name]))

        let (_, keyExchange) = try await Self.negotiate(with: TestServer.nist, algorithms: policy)

        #expect(keyExchange == KeyExchange(name: name, isPostQuantum: false))
    }

    /// Why the policy offers sntrup761x25519-sha512 under both names: offered only its standard
    /// name, OpenSSH 9 falls back to a classical key exchange.
    @Test(.enabled(TestServer.openSSH9NotRunning) { await TestServer.isOpenSSH9Running })
    func openSSH9DoesNotKnowTheStandardNameOfSNTRUP() async throws {
        let policy = AlgorithmPolicy.standard.overridden(
            by: AlgorithmOverrides(
                keyExchanges: ["mlkem768x25519-sha256", "sntrup761x25519-sha512", "curve25519-sha256"]))

        let (_, keyExchange) = try await Self.negotiate(with: TestServer.openSSH9, algorithms: policy)

        #expect(keyExchange == KeyExchange(name: "curve25519-sha256", isPostQuantum: false))
    }

    /// Shello's order decides, not the server's: offered curve25519-sha256 first, OpenSSH 10 takes it.
    /// A host's own lists are how the order changes.
    @Test(.enabled(TestServer.notRunning) { await TestServer.isRunning })
    func thePolicysOrderDecides() async throws {
        let policy = AlgorithmPolicy.standard.overridden(
            by: AlgorithmOverrides(keyExchanges: ["curve25519-sha256", "mlkem768x25519-sha256"]))

        let (_, keyExchange) = try await Self.negotiate(with: TestServer.server, algorithms: policy)

        #expect(keyExchange == KeyExchange(name: "curve25519-sha256", isPostQuantum: false))
    }

    /// The standard policy's cipher comes first: chacha20-poly1305, which authenticates itself, so
    /// no MAC is used.
    @Test(.enabled(TestServer.notRunning) { await TestServer.isRunning })
    func openSSH10NegotiatesChaCha20Poly1305() async throws {
        let connection = TestServer.connection()
        _ = try await connection.connect()

        #expect(await connection.negotiatedCipher == "chacha20-poly1305@openssh.com")
        #expect(await connection.negotiatedMAC == "aead-poly1305")
        await connection.close()
    }

    /// The ciphers and MACs reach the server as the policy lists them: offered only AES-CTR and
    /// HMAC-SHA-512 encrypt-then-MAC, OpenSSH takes those.
    @Test(.enabled(TestServer.notRunning) { await TestServer.isRunning })
    func ciphersAndMACsFollowThePolicy() async throws {
        let policy = AlgorithmPolicy.standard.overridden(
            by: AlgorithmOverrides(ciphers: ["aes128-ctr"], macs: ["hmac-sha2-512-etm@openssh.com"]))
        let connection = SSHConnection(
            server: TestServer.server, username: TestServer.user, connectTimeout: TestServer.connectTimeout,
            algorithms: policy)
        _ = try await connection.connect()

        #expect(await connection.negotiatedCipher == "aes128-ctr")
        #expect(await connection.negotiatedMAC == "hmac-sha2-512-etm@openssh.com")
        await connection.close()
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
        let cipher = await connection.negotiatedCipher
        await connection.close()
        print(
            "\(server) greets with \(banner); offered \(algorithms.keyExchanges.joined(separator: ",")), "
                + "libssh negotiated \(keyExchange?.name ?? "nothing") and \(cipher ?? "no cipher")")
        return (banner, keyExchange)
    }
}

extension TestServer {
    /// OpenSSH 9.6 on Ubuntu 24.04, in Docker only.
    static let openSSH9 = Server(address: address, port: 2223)
    /// OpenSSH 10 with post-quantum key exchange off: in Docker, or this Mac's own sshd.
    static let classical = Server(address: address, port: 2224)
    /// OpenSSH 8.8 on Alpine 3.15, in Docker only.
    static let openSSH8 = Server(address: address, port: 2225)
    /// OpenSSH 10 with the NIST curves and Diffie-Hellman groups only, as in FIPS mode: in Docker,
    /// or this Mac's own sshd.
    static let nist = Server(address: address, port: 2226)

    static var isOpenSSH9Running: Bool {
        get async { await openSSH9Probe.value }
    }

    static var isClassicalRunning: Bool {
        get async { await classicalProbe.value }
    }

    static var isOpenSSH8Running: Bool {
        get async { await openSSH8Probe.value }
    }

    static var isNISTRunning: Bool {
        get async { await nistProbe.value }
    }

    private static let openSSH9Probe = Task { await hasSSHBanner(port: openSSH9.port) }
    private static let classicalProbe = Task { await hasSSHBanner(port: classical.port) }
    private static let openSSH8Probe = Task { await hasSSHBanner(port: openSSH8.port) }
    private static let nistProbe = Task { await hasSSHBanner(port: nist.port) }

    static let openSSH9NotRunning: Comment =
        "The OpenSSH 9 test server is not running on localhost:2223. Start it with TestServers/ssh-server.sh (TestServers/README.md)."
    static let classicalNotRunning: Comment =
        "The test server without post-quantum key exchange is not running on localhost:2224. Start it with TestServers/ssh-server.sh (TestServers/README.md)."
    static let openSSH8NotRunning: Comment =
        "The OpenSSH 8.8 test server is not running on localhost:2225. Start it with TestServers/ssh-server.sh (TestServers/README.md)."
    static let nistNotRunning: Comment =
        "The test server without curve25519 is not running on localhost:2226. Start it with TestServers/ssh-server.sh (TestServers/README.md)."
}
