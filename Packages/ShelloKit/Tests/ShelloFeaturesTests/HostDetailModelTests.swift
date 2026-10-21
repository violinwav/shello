import Foundation
import ShelloModel
import ShelloSecurity
import ShelloStorage
import Testing

@testable import ShelloFeatures

@Suite(.timeLimit(.minutes(1)))
struct HostDetailModelTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
    }

    @Test func showsTheHostAndFollowsItsChanges() async throws {
        var nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        let model = HostDetailModel(repository: repository, hostID: nas.id)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await waitUntil { model.host != nil }
        #expect(model.host == nas)

        nas.address = "10.0.0.2"
        try await repository.update(nas)

        await waitUntil { model.host?.address == "10.0.0.2" }
    }

    @Test func namesTheHostsGroupAndTagsByName() async throws {
        let homelab = HostGroup(name: "Homelab")
        let staging = Tag(name: "Staging", color: .purple)
        let backups = Tag(name: "backups", color: .green)
        try await repository.create(homelab)
        try await repository.create(staging)
        try await repository.create(backups)
        try await repository.create(Tag(name: "Production", color: .red))
        let nas = Host(
            name: "nas", address: "nas.lan", username: "admin", groupID: homelab.id, tagIDs: [staging.id, backups.id])
        try await repository.create(nas)
        let model = HostDetailModel(repository: repository, hostID: nas.id)

        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await waitUntil { model.groupName != nil && model.hostTags.count == 2 }

        #expect(model.groupName == "Homelab")
        #expect(model.hostTags.map(\.name) == ["backups", "Staging"])
    }

    /// The host's SSH key by name, or that it is not on this device (README section 15).
    @Test func namesTheHostsSSHKey() async throws {
        let keys = TestKeys()
        let homelab = try await keys.make("homelab")
        let nas = Host(name: "nas", address: "nas.lan", username: "admin", sshKeyID: homelab.id)
        let db = Host(name: "db", address: "db.lan", username: "admin", sshKeyID: UUID())
        let vault = Host(name: "vault", address: "vault.lan", username: "admin")
        for host in [nas, db, vault] {
            try await repository.create(host)
        }

        var summaries: [String] = []
        for host in [nas, db, vault] {
            let model = HostDetailModel(repository: repository, keys: keys.store, hostID: host.id)
            let observing = Task { await model.observe() }
            await waitUntil { model.host != nil }
            observing.cancel()
            summaries.append(model.sshKeySummary)
        }

        #expect(summaries == ["homelab", "Not on this device", "None"])
    }

    /// The Keychain tells nobody about a new key, such as one the user made from the host editor:
    /// the details read the keys again.
    @Test func namesAnSSHKeyMadeSinceTheDetailsOpened() async throws {
        let keys = TestKeys()
        let id = UUID()
        let model = HostDetailModel(repository: repository, keys: keys.store, hostID: id)
        let key = try await keys.make("homelab")
        try await repository.create(Host(id: id, name: "nas", address: "nas.lan", username: "admin", sshKeyID: key.id))
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await waitUntil { model.host != nil }
        #expect(model.sshKeySummary == "Not on this device")

        model.loadSSHKeys()

        #expect(model.sshKeySummary == "homelab")
    }

    @Test func deletedHostIsGone() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        let model = HostDetailModel(repository: repository, hostID: nas.id)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await waitUntil { model.host != nil }
        #expect(!model.isGone)

        #expect(await model.delete())

        await waitUntil { model.isGone }
        #expect(try await repository.host(id: nas.id) == nil)
    }

    @Test func deletingTheHostRemovesItsPassword() async throws {
        let secrets = TestSecrets()
        let nas = Host(name: "nas", address: "nas.lan", username: "admin", authMethod: .password)
        try await repository.create(nas)
        try secrets.store.store(Secret(utf8: "hunter2"), as: .password(of: nas.id))
        let model = HostDetailModel(repository: repository, secrets: secrets.store, hostID: nas.id)

        #expect(await model.delete())

        #expect(try await repository.host(id: nas.id) == nil)
        #expect(try secrets.password(of: nas.id) == nil)
    }

    @Test func unknownHostIsGone() async throws {
        let model = HostDetailModel(repository: repository, hostID: UUID())

        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        await waitUntil { model.isGone }
    }

    @Test func favoritingTheHostStoresIt() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        let model = HostDetailModel(repository: repository, hostID: nas.id)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await waitUntil { model.host != nil }

        await model.setFavorite(true)

        await waitUntil { model.host?.isFavorite == true }
        #expect(try await repository.host(id: nas.id)?.isFavorite == true)
    }
}
