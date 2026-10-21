import Foundation
import ShelloModel
import ShelloSecurity
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

/// The host editor's password, which goes into the Keychain only (README section 13).
@Suite(.timeLimit(.minutes(1)))
struct HostEditorPasswordTests {
    let test: TestDatabase
    let secrets = TestSecrets()
    var repository: HostRepository { test.repository }

    init() throws {
        test = try TestDatabase()
    }

    @Test func newHostWithAPasswordKeepsItInTheKeychainUnderTheHostsIdentifier() async throws {
        let model = newPasswordHost()
        model.password = "hunter2"

        #expect(await model.save())

        let host = try #require(try await repository.hosts().first)
        #expect(host.authMethod == .password)
        #expect(try secrets.password(of: host.id) == "hunter2")
        // The typed string goes once the password is stored.
        #expect(model.password.isEmpty)
    }

    @Test func passwordIsOptional() async throws {
        let model = newPasswordHost()

        #expect(model.passwordPrompt == "optional")
        #expect(await model.save())

        let host = try #require(try await repository.hosts().first)
        #expect(try secrets.password(of: host.id) == nil)
    }

    @Test func passwordFieldIsOnlyOfferedForThePasswordMethod() {
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nil)
        #expect(!model.offersPassword)

        model.draft.authMethod = .password
        #expect(model.offersPassword)

        model.draft.authMethod = .keyboardInteractive
        #expect(!model.offersPassword)
    }

    /// Previews have no Keychain.
    @Test func editorWithoutTheKeychainOffersNoPassword() {
        let model = HostEditorModel(repository: repository, host: nil)
        model.draft.authMethod = .password

        #expect(!model.offersPassword)
    }

    @Test func passwordTypedForAnotherMethodIsNotStored() async throws {
        let model = newPasswordHost()
        model.password = "hunter2"
        model.draft.authMethod = .sshKey

        #expect(await model.save())

        let host = try #require(try await repository.hosts().first)
        #expect(try secrets.password(of: host.id) == nil)
    }

    @Test func typedPasswordCountsAsAChange() throws {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin", authMethod: .password)
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)
        #expect(!model.hasChanges)

        model.password = "hunter2"

        #expect(model.hasChanges)
    }

    @Test func editorSaysThatAPasswordIsSaved() async throws {
        let nas = try await storedHost(password: "hunter2")

        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)

        #expect(model.hasStoredPassword)
        #expect(model.passwordPrompt == "saved")
        #expect(model.passwordHint == "A password is saved. Typing a new one replaces it.")
        #expect(model.managesStoredPassword)
        #expect(model.password.isEmpty)
    }

    /// While the user types a new password, there is nothing to remove: it replaces the saved one.
    @Test func typingANewPasswordHidesTheRemoval() async throws {
        let nas = try await storedHost(password: "hunter2")
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)

        model.password = "correct horse"

        #expect(!model.managesStoredPassword)
    }

    @Test func typingANewPasswordReplacesTheSavedOne() async throws {
        let nas = try await storedHost(password: "hunter2")
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)

        model.password = "correct horse"
        #expect(await model.save())

        #expect(try secrets.password(of: nas.id) == "correct horse")
    }

    @Test func savingWithoutTypingKeepsTheSavedPassword() async throws {
        let nas = try await storedHost(password: "hunter2")
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)

        model.draft.notes = "Backups"
        #expect(await model.save())

        #expect(try secrets.password(of: nas.id) == "hunter2")
    }

    @Test func removingTheSavedPasswordTakesEffectWhenTheHostIsSaved() async throws {
        let nas = try await storedHost(password: "hunter2")
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)

        model.removeStoredPassword()
        #expect(model.hasChanges)
        #expect(model.passwordPrompt == "optional")
        #expect(model.passwordHint.isEmpty)
        #expect(model.passwordNote == "Saving removes the saved password.")
        // The same row offers to keep it after all.
        #expect(model.managesStoredPassword)
        #expect(try secrets.password(of: nas.id) == "hunter2")

        #expect(await model.save())
        #expect(try secrets.password(of: nas.id) == nil)
        #expect(!model.managesStoredPassword)
    }

    @Test func keepingTheSavedPasswordUndoesTheRemoval() async throws {
        let nas = try await storedHost(password: "hunter2")
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)
        model.removeStoredPassword()

        model.keepStoredPassword()

        #expect(!model.hasChanges)
        #expect(model.passwordPrompt == "saved")
        #expect(model.passwordNote == nil)
        #expect(await model.save())
        #expect(try secrets.password(of: nas.id) == "hunter2")
    }

    /// Cancel throws the editor away, and the removal with it.
    @Test func removalIsNotStoredUntilTheHostIsSaved() async throws {
        let nas = try await storedHost(password: "hunter2")
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)

        model.removeStoredPassword()

        #expect(try secrets.password(of: nas.id) == "hunter2")
    }

    /// A password the host's method no longer uses does not stay in the Keychain.
    @Test func switchingToAnotherMethodRemovesTheSavedPassword() async throws {
        let nas = try await storedHost(password: "hunter2")
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)

        model.draft.authMethod = .sshKey
        #expect(model.passwordNote == "Saving removes the saved password, which only the Password method uses.")
        #expect(await model.save())

        #expect(try secrets.password(of: nas.id) == nil)
        #expect(try await repository.host(id: nas.id)?.authMethod == .sshKey)
    }

    @Test func deletingTheHostRemovesItsPassword() async throws {
        let nas = try await storedHost(password: "hunter2")
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)

        #expect(await model.delete())

        #expect(try await repository.host(id: nas.id) == nil)
        #expect(try secrets.password(of: nas.id) == nil)
    }

    /// The host went while the editor was open, and its password went with it.
    @Test func passwordForAHostDeletedMeanwhileIsNotKept() async throws {
        let nas = try await storedHost(password: "hunter2")
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nas)
        try await repository.deleteHost(id: nas.id, removingSecretsFrom: secrets.store)

        model.password = "correct horse"
        #expect(await model.save() == false)

        #expect(model.saveError == "This host was deleted while you were editing it.")
        #expect(try secrets.password(of: nas.id) == nil)
    }

    /// A new host that cannot be stored leaves no password behind.
    @Test func newHostThatIsNotStoredLeavesNoPassword() async throws {
        let model = newPasswordHost()
        model.password = "hunter2"
        // A group that does not exist breaks the database's foreign key.
        model.draft.groupID = UUID()

        #expect(await model.save() == false)

        #expect(model.saveError != nil)
        #expect(try await repository.hosts().isEmpty)
        #expect(try secrets.password(of: model.hostID) == nil)
    }

    /// The Keychain refuses nothing while the unlock window is open; once app lock has engaged it
    /// refuses the write, and nothing is saved.
    @Test func hostIsNotSavedWhenItsPasswordCannotBeStored() async throws {
        let model = newPasswordHost()
        model.password = "hunter2"
        secrets.window.close()

        #expect(await model.save() == false)

        #expect(model.saveError != nil)
        #expect(try await repository.hosts().isEmpty)
    }

    /// A new host with the password method, whose required fields are filled in.
    private func newPasswordHost() -> HostEditorModel {
        let model = HostEditorModel(repository: repository, secrets: secrets.store, host: nil)
        model.draft.name = "nas"
        model.draft.address = "nas.lan"
        model.draft.authMethod = .password
        return model
    }

    /// Stores a host that signs in with `password`.
    private func storedHost(password: String) async throws -> Host {
        let nas = Host(name: "nas", address: "nas.lan", username: "admin", authMethod: .password)
        try await repository.create(nas)
        try secrets.store.store(Secret(utf8: password), as: .password(of: nas.id))
        return nas
    }
}
