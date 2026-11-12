import Foundation
import ShelloModel
import Testing

@testable import ShelloStorage

/// Storing an import from OpenSSH's files (README section 3): the hosts and the host keys in one
/// transaction, and never a trusted host key replaced, whatever the import was planned against.
struct HostImportRepositoryTests {
    let database: TestDatabase
    let imports: HostImportRepository
    let nas = Server(address: "nas.lan", port: 22)
    let router = Server(address: "router.lan", port: 2222)

    init() throws {
        database = try TestDatabase()
        imports = HostImportRepository(database.database, now: { [clock = database.clock] in clock.now })
    }

    @Test func hostsAndKeysAreStored() async throws {
        let bastion = Host(name: "bastion", address: "bastion.example.com", username: "jump")
        let web = Host(
            name: "web", address: "10.0.1.21", username: "deploy", jumpHostIDs: [bastion.id],
            portForwards: [PortForward(port: 8080, kind: .dynamic)])

        let result = try await imports.importHosts([bastion, web], trusting: [nas: HostKeyRepositoryTests.keyA])

        #expect(try await database.repository.hosts() == [bastion, web])
        #expect(try await database.hostKeys.trustedKey(of: nas)?.key == HostKeyRepositoryTests.keyA)
        #expect(result.trusted == [nas])
        #expect(result.alreadyTrusted.isEmpty)
        #expect(result.keptOtherKey.isEmpty)
    }

    /// The acceptance criterion: an import never replaces a host key Shello trusts, even one trusted
    /// after the import was planned. The same key changes nothing.
    @Test func importNeverReplacesATrustedHostKey() async throws {
        try await database.hostKeys.trust(HostKeyRepositoryTests.keyA, of: nas)
        try await database.hostKeys.trust(HostKeyRepositoryTests.keyB, of: router)
        let before = try await database.hostKeys.trustedKey(of: nas)
        database.clock.set(database.clock.now.addingTimeInterval(60))

        let result = try await imports.importHosts(
            [], trusting: [nas: HostKeyRepositoryTests.keyB, router: HostKeyRepositoryTests.keyB])

        #expect(try await database.hostKeys.trustedKey(of: nas) == before)
        #expect(try await database.hostKeys.trustedKey(of: nas)?.key == HostKeyRepositoryTests.keyA)
        #expect(result.keptOtherKey == [nas])
        #expect(result.alreadyTrusted == [router])
        #expect(result.trusted.isEmpty)
    }

    @Test func importIsOneTransaction() async throws {
        let existing = Host(name: "existing", address: "a.example.com", username: "me")
        try await database.repository.create(existing)
        let snapshot = try await database.snapshot()
        let new = Host(name: "new", address: "b.example.com", username: "me")

        // The second host has the identifier of one in the database, so its insert fails.
        await #expect(throws: (any Error).self) {
            try await imports.importHosts([new, existing], trusting: [nas: HostKeyRepositoryTests.keyA])
        }

        #expect(try await database.snapshot() == snapshot)
        #expect(try await database.hostKeys.trustedKey(of: nas) == nil)
    }

    @Test func savedHostsAndTrustedKeysLeaveDeletedHostsOut() async throws {
        let kept = Host(name: "kept", address: "a.example.com", username: "me")
        let deleted = Host(name: "deleted", address: "b.example.com", username: "me")
        try await database.repository.create(kept)
        try await database.repository.create(deleted)
        try await database.repository.deleteHost(id: deleted.id)
        try await database.hostKeys.trust(HostKeyRepositoryTests.keyA, of: nas)

        let saved = try await imports.savedHostsAndTrustedKeys()

        #expect(saved.hosts == [kept])
        #expect(saved.trustedKeys.mapValues(\.key) == [nas: HostKeyRepositoryTests.keyA])
    }
}
