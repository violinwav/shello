import Foundation
import ShelloModel
import ShelloStorage
import Testing

@testable import ShelloFeatures

@Suite(.timeLimit(.minutes(1)))
struct HostEditorModelTests {
    let test: TestDatabase
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
    }

    // MARK: - Creating

    @Test func creatingAHostStoresIt() async throws {
        let model = HostEditorModel(repository: repository, host: nil)
        model.draft.name = "prod-api-02"
        model.draft.address = "10.0.4.22"
        model.draft.username = "deploy"
        model.draft.startupCommand = "tmux new -A -s main"

        #expect(await model.save())

        let hosts = try await repository.hosts()
        #expect(hosts.map(\.name) == ["prod-api-02"])
        #expect(hosts.first?.address == "10.0.4.22")
        #expect(hosts.first?.port == 22)
        #expect(hosts.first?.username == "deploy")
        #expect(hosts.first?.startupCommand == "tmux new -A -s main")
    }

    @Test func newHostEditorIsTitledNewHostAndHasNoChanges() {
        let model = HostEditorModel(repository: repository, host: nil)

        #expect(model.title == "New Host")
        #expect(!model.hasChanges)
        #expect(!model.isEditing)
    }

    @Test func savingADraftWithProblemsStoresNothingAndShowsEveryProblem() async throws {
        let model = HostEditorModel(repository: repository, host: nil)
        model.draft.port = "70000"

        #expect(await model.save() == false)

        #expect(try await repository.hosts().isEmpty)
        #expect(model.visibleProblem(for: .name) == "Enter a name.")
        #expect(model.visibleProblem(for: .address) == "Enter an address.")
        #expect(model.visibleProblem(for: .port) == "Enter a port from 1 to 65535.")
        #expect(model.firstProblemField == .name)
        #expect(model.visibleProblems == ["Enter a name.", "Enter an address.", "Enter a port from 1 to 65535."])
    }

    /// A confirmation names the host as it is stored, not as the user is retyping it.
    @Test func storedNameIgnoresTheDraft() {
        let model = HostEditorModel(
            repository: repository, host: Host(name: "nas", address: "nas.lan", username: "admin"))

        model.draft.name = ""

        #expect(model.storedName == "nas")
    }

    /// A field the user has not been to yet is not marked as wrong.
    @Test func problemShowsOnceTheUserLeavesTheField() {
        let model = HostEditorModel(repository: repository, host: nil)
        #expect(model.visibleProblem(for: .name) == nil)

        model.didLeave(.name)

        #expect(model.visibleProblem(for: .name) == "Enter a name.")
        #expect(model.visibleProblem(for: .address) == nil)
    }

    @Test func fixedProblemDisappears() {
        let model = HostEditorModel(repository: repository, host: nil)
        model.didLeave(.name)

        model.draft.name = "nas"

        #expect(model.visibleProblem(for: .name) == nil)
    }

    // MARK: - Editing

    @Test func editingAHostStoresTheChanges() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        let model = HostEditorModel(repository: repository, host: nas)
        model.draft.address = "10.0.0.2"
        model.draft.port = "2222"

        #expect(await model.save())

        let stored = try await repository.host(id: nas.id)
        #expect(stored?.address == "10.0.0.2")
        #expect(stored?.port == 2222)
        #expect(stored?.name == "nas")
    }

    @Test func hostEditorIsTitledEditHostAndNoticesChanges() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        let model = HostEditorModel(repository: repository, host: nas)
        #expect(model.title == "Edit Host")
        #expect(model.isEditing)
        #expect(!model.hasChanges)

        model.draft.name = "nas-2"

        #expect(model.hasChanges)
    }

    @Test func savingKeepsChangesMadeSinceTheEditorOpened() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        let model = HostEditorModel(repository: repository, host: nas)
        var favorite = nas
        favorite.isFavorite = true
        try await repository.update(favorite)

        model.draft.name = "nas-2"
        #expect(await model.save())

        let stored = try await repository.host(id: nas.id)
        #expect(stored?.name == "nas-2")
        #expect(stored?.isFavorite == true)
    }

    @Test func savingAHostThatWasDeletedMeanwhileFails() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        let model = HostEditorModel(repository: repository, host: nas)
        try await repository.deleteHost(id: nas.id)

        model.draft.name = "nas-2"

        #expect(await model.save() == false)
        #expect(model.saveError != nil)
    }

    @Test func deletingTheHostRemovesIt() async throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin")
        try await repository.create(nas)
        let model = HostEditorModel(repository: repository, host: nas)

        #expect(await model.delete())

        #expect(try await repository.host(id: nas.id) == nil)
    }

    // MARK: - Groups and tags

    @Test func editorOffersTheStoredGroupsAndTags() async throws {
        try await repository.create(HostGroup(name: "Work"))
        try await repository.create(HostGroup(name: "Homelab"))
        try await repository.create(Tag(name: "Staging", color: .purple))
        let model = HostEditorModel(repository: repository, host: nil)

        let observing = Task { await model.observeGroupsAndTags() }
        defer { observing.cancel() }
        await waitUntil { model.groups.count == 2 && model.tags.count == 1 }

        #expect(model.groups.map(\.name) == ["Homelab", "Work"])
        #expect(model.tags.map(\.name) == ["Staging"])
    }

    @Test func tagCreatedInTheEditorIsSelectedAndStoredWithTheHost() async throws {
        let model = filledEditor()

        let staging = try #require(model.addTag(named: "Staging", color: .purple))
        #expect(model.draft.tagIDs == [staging.id])
        #expect(model.tags.map(\.name) == ["Staging"])
        #expect(await model.save())

        #expect(try await repository.tags() == [staging])
        #expect(try await repository.hosts().first?.tagIDs == [staging.id])
    }

    @Test func tagCreatedInTheEditorIsNotStoredUntilTheHostIsSaved() async throws {
        let model = filledEditor()

        _ = model.addTag(named: "Staging", color: .purple)

        #expect(try await repository.tags().isEmpty)
    }

    @Test func tagCreatedAndDeselectedIsNotStored() async throws {
        let model = filledEditor()
        let staging = try #require(model.addTag(named: "Staging", color: .purple))

        model.toggleTag(staging)
        #expect(await model.save())

        #expect(try await repository.tags().isEmpty)
    }

    @Test func addingATagWithAnExistingNameSelectsThatTag() async throws {
        let production = Tag(name: "Production", color: .red)
        try await repository.create(production)
        let model = filledEditor()
        let observing = Task { await model.observeGroupsAndTags() }
        defer { observing.cancel() }
        await waitUntil { model.tags.count == 1 }

        let added = model.addTag(named: " production ", color: .blue)

        #expect(added == production)
        #expect(model.tags == [production])
        #expect(model.draft.tagIDs == [production.id])
    }

    @Test func blankTagNameAddsNothing() {
        let model = filledEditor()

        #expect(model.addTag(named: "  ", color: .blue) == nil)
        #expect(model.tags.isEmpty)
    }

    @Test func togglingATagSelectsAndDeselectsIt() async throws {
        let staging = Tag(name: "Staging", color: .purple)
        try await repository.create(staging)
        let model = filledEditor()

        model.toggleTag(staging)
        #expect(model.draft.tagIDs == [staging.id])
        model.toggleTag(staging)
        #expect(model.draft.tagIDs.isEmpty)
    }

    @Test func newTagSuggestsTheFirstColorNoTagHasYet() async throws {
        try await repository.create(Tag(name: "Production", color: .red))
        let model = filledEditor()
        let observing = Task { await model.observeGroupsAndTags() }
        defer { observing.cancel() }
        await waitUntil { model.tags.count == 1 }
        #expect(model.suggestedTagColor == .orange)

        _ = model.addTag(named: "Staging", color: .orange)

        #expect(model.suggestedTagColor == .yellow)
    }

    @Test func groupCreatedInTheEditorIsSelectedAndStoredWithTheHost() async throws {
        let model = filledEditor()

        let homelab = try #require(model.addGroup(named: "Homelab"))
        #expect(model.draft.groupID == homelab.id)
        #expect(await model.save())

        #expect(try await repository.groups() == [homelab])
        #expect(try await repository.hosts().first?.groupID == homelab.id)
    }

    @Test func groupCreatedAndThenNotChosenIsNotStored() async throws {
        let model = filledEditor()

        _ = model.addGroup(named: "Homelab")
        model.draft.groupID = nil
        #expect(await model.save())

        #expect(try await repository.groups().isEmpty)
    }

    @Test func addingAGroupWithAnExistingNameChoosesThatGroup() async throws {
        let homelab = HostGroup(name: "Homelab")
        try await repository.create(homelab)
        let model = filledEditor()
        let observing = Task { await model.observeGroupsAndTags() }
        defer { observing.cancel() }
        await waitUntil { model.groups.count == 1 }

        #expect(model.addGroup(named: "homelab") == homelab)
        #expect(model.groups == [homelab])
        #expect(model.draft.groupID == homelab.id)
    }

    // MARK: - SSH key

    @Test func hostWithoutAnSSHKeySaysSo() {
        let model = HostEditorModel(repository: repository, host: nil)

        #expect(model.sshKeySummary == "None")
    }

    /// No SSH key can be created on this device yet, so a key that a host refers to is elsewhere.
    @Test func hostWithAnSSHKeySaysItIsNotOnThisDevice() {
        let host = Host(name: "nas", address: "nas.lan", username: "admin", sshKeyID: UUID())

        let model = HostEditorModel(repository: repository, host: host)

        #expect(model.sshKeySummary == "Not on this device")
    }

    /// An editor for a new host whose required fields are filled in.
    private func filledEditor() -> HostEditorModel {
        let model = HostEditorModel(repository: repository, host: nil)
        model.draft.name = "nas"
        model.draft.address = "nas.lan"
        return model
    }
}
