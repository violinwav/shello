import Foundation
import ShelloModel
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
