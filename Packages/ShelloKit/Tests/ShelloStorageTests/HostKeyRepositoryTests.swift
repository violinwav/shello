import Foundation
import ShelloModel
import Testing

@testable import ShelloStorage

/// The trust store (README section 3): one trusted host key per server, its address and port.
struct HostKeyRepositoryTests {
    let database: TestDatabase
    let server = Server(address: "prod-api-01.example.com", port: 22)

    init() throws {
        database = try TestDatabase()
    }

    @Test func serverWithoutATrustedKeyHasNone() async throws {
        #expect(try await database.hostKeys.trustedKey(of: server) == nil)
    }

    @Test func trustedKeyIsKeptWithTheTimeItWasTrusted() async throws {
        try await database.hostKeys.trust(Self.keyA, of: server)

        let trusted = try await database.hostKeys.trustedKey(of: server)
        #expect(trusted == TrustedHostKey(key: Self.keyA, trustedAt: database.clock.now))
    }

    /// Trust belongs to the server, so it covers every host that points at it, whatever the case of
    /// the host's address.
    @Test func trustCoversEveryHostOfTheServer() async throws {
        let host = Host(name: "api", address: "PROD-API-01.example.com", username: "deploy")
        let otherUser = Host(name: "api as root", address: "prod-api-01.EXAMPLE.com", username: "root")
        try await database.hostKeys.trust(Self.keyA, of: host.server)

        #expect(try await database.hostKeys.trustedKey(of: otherUser.server)?.key == Self.keyA)
    }

    @Test func serverOnAnotherPortIsNotTrusted() async throws {
        try await database.hostKeys.trust(Self.keyA, of: server)

        let otherPort = Server(address: server.address, port: 2222)
        #expect(try await database.hostKeys.trustedKey(of: otherPort) == nil)
    }

    @Test func trustingTheTrustedKeyAgainChangesNothing() async throws {
        try await database.hostKeys.trust(Self.keyA, of: server)
        let before = try await database.snapshot()
        database.clock.set(Date(timeIntervalSinceReferenceDate: 800_100_000))

        try await database.hostKeys.trust(Self.keyA, of: server)

        #expect(try await database.snapshot() == before)
    }

    /// Replacing a trusted key takes an explicit action of its own (README section 3): trusting
    /// another key fails and keeps the trusted one.
    @Test func trustingAnotherKeyForATrustedServerFails() async throws {
        try await database.hostKeys.trust(Self.keyA, of: server)
        let trusted = try #require(try await database.hostKeys.trustedKey(of: server))

        await #expect(throws: HostKeyRepositoryError.otherKeyTrusted(server, trusted: trusted)) {
            try await database.hostKeys.trust(Self.keyB, of: server)
        }
        #expect(try await database.hostKeys.trustedKey(of: server) == trusted)
    }

    /// The host keys of TestServers/keys: host key a and host key b.
    static let keyA = HostKey(
        algorithm: "ssh-ed25519",
        wireRepresentation: Data(
            base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIHgTJMsflS9c2SZNLqrNUxilEPdrI1trFCrvwBsv0BQ9")!,
        fingerprint: "SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY")
    static let keyB = HostKey(
        algorithm: "ssh-ed25519",
        wireRepresentation: Data(
            base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIIJJGCfEG93QAyNvR5/qMneE615D5dVdNz8eF8nfUV2G")!,
        fingerprint: "SHA256:vRTlNPuThVvvrnjbeKgZ/H5Ud52Nq2MKVToLDK4pofI")
}
