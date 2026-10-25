import Foundation
import Observation
import ShelloModel
import ShelloSecurity
import ShelloStorage
import os

/// The new and edit host sheet: a draft of every MVP field, the groups and tags to choose from, and
/// the groups and tags created on the way, which are stored only with the host.
///
/// The host's password goes into the Keychain, never into the host: the Keychain item is found by
/// the host's identifier (`SecretID.password(of:)`). The host refers to its SSH key by identifier
/// too, and the key may be on another device (README section 15).
///
/// Its jump hosts (README section 3) are chosen among the saved SSH hosts, which the editor follows,
/// and the draft's route is checked against them: one that reaches a host twice, has too many jump
/// hosts or one that is not an SSH host is refused, and a missing jump host is shown as missing.
@Observable
final class HostEditorModel {
    let repository: HostRepository
    /// The Keychain's secrets. Without it, as in previews, the editor offers no password.
    let secrets: SecretStore?
    /// The SSH keys on this device. Without it, as in previews, the editor names the host's SSH key
    /// but offers no choice.
    let keys: SSHKeyStore?
    var draft: HostDraft
    /// Set when saving or deleting fails; the sheet shows it and clears it.
    var saveError: String?
    /// The password the user typed, or empty to keep the one stored. The secure field hands it over
    /// as a string; saving turns it into a `Secret` for the Keychain and empties it.
    var password = ""
    /// Whether the Keychain holds a password for the host.
    private(set) var hasStoredPassword = false
    /// Whether saving removes the stored password, as the user asked.
    private(set) var removesStoredPassword = false
    /// The SSH keys on this device, by name.
    private(set) var sshKeys: [SSHKey] = []

    /// The host as it was read when the editor opened, or a new host's defaults.
    private let base: Host
    private let original: HostDraft
    let isEditing: Bool

    private var storedGroups: [HostGroup] = []
    private var storedTags: [Tag] = []
    /// The saved hosts, by name, among which the jump hosts are chosen and looked up.
    private(set) var savedHosts: [Host] = []
    /// Groups and tags created in this editor and not stored yet.
    private var newGroups: [HostGroup] = []
    private var newTags: [Tag] = []

    private var attemptedSave = false
    private var leftFields: Set<HostDraft.Field> = []

    /// An editor for `host` as the caller last read it, or for a new host.
    init(repository: HostRepository, secrets: SecretStore? = nil, keys: SSHKeyStore? = nil, host: Host?) {
        self.repository = repository
        self.secrets = secrets
        self.keys = keys
        isEditing = host != nil
        base = host ?? Host(name: "", address: "", username: "")
        original = HostDraft(base)
        draft = original
        if isEditing, let secrets {
            do {
                hasStoredPassword = try secrets.contains(.password(of: base.id))
            } catch {
                Self.logger.error("Could not look for a host's password: \(error)")
            }
        }
        loadSSHKeys()
    }

    var title: String { isEditing ? "Edit Host" : "New Host" }

    /// The identifier of the host being edited, or of the new one.
    var hostID: Host.ID { base.id }

    /// Whether closing the editor would lose anything the user entered.
    var hasChanges: Bool { draft != original || !password.isEmpty || removesStoredPassword }

    /// Whether the editor shows the password field: for the password method, with the Keychain.
    var offersPassword: Bool { secrets != nil && draft.authMethod == .password }

    /// The password field's placeholder: whether a password is stored, which typing replaces.
    var passwordPrompt: String {
        keepsStoredPassword ? "saved" : "optional"
    }

    /// What VoiceOver adds to the password field, whose placeholder says this in one word.
    var passwordHint: String {
        keepsStoredPassword ? "A password is saved. Typing a new one replaces it." : ""
    }

    /// Whether the editor offers to remove the stored password, or, once the user asked for that, to
    /// keep it after all.
    var managesStoredPassword: Bool {
        offersPassword && hasStoredPassword && password.isEmpty
    }

    private var keepsStoredPassword: Bool {
        hasStoredPassword && !removesStoredPassword
    }

    /// What saving does to the stored password, when the user has asked for anything, for the
    /// footer under the field.
    var passwordNote: String? {
        guard hasStoredPassword, password.isEmpty || draft.authMethod != .password else { return nil }
        if draft.authMethod != .password {
            return "Saving removes the saved password, which only the Password method uses."
        }
        return removesStoredPassword ? "Saving removes the saved password." : nil
    }

    /// Removes the stored password when the host is saved.
    func removeStoredPassword() {
        removesStoredPassword = true
    }

    /// Keeps the stored password after all.
    func keepStoredPassword() {
        removesStoredPassword = false
    }

    /// Every group the host can be in, by name.
    var groups: [HostGroup] {
        (storedGroups + newGroups).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every tag the host can have, by name.
    var tags: [Tag] {
        (storedTags + newTags).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The colour for a new tag: the first one no tag has yet.
    var suggestedTagColor: Tag.Color {
        Tag.Color.allCases.first { color in !tags.contains { $0.color == color } } ?? .gray
    }

    /// Whether the editor offers a choice of SSH key: with the SSH keys of this device.
    var offersSSHKeyChoice: Bool { keys != nil }

    /// The chosen SSH key, if it is on this device.
    var chosenSSHKey: SSHKey? {
        draft.sshKeyID.flatMap { id in sshKeys.first { $0.id == id } }
    }

    /// Whether the host refers to an SSH key that is not on this device: one made on another device,
    /// as after an import, or one deleted since (README section 15).
    var sshKeyIsMissing: Bool {
        draft.sshKeyID != nil && chosenSSHKey == nil
    }

    /// The host's SSH key, as the editor names it.
    var sshKeySummary: String {
        if let chosenSSHKey { return chosenSSHKey.comment }
        return sshKeyIsMissing ? "Not on this device" : "None"
    }

    /// Chooses the SSH key `id`, or none.
    func chooseSSHKey(_ id: SSHKey.ID?) {
        draft.sshKeyID = id
    }

    /// Chooses `key`, which the user just made from the editor.
    func didCreate(_ key: SSHKey) {
        loadSSHKeys()
        if !sshKeys.contains(key) { sshKeys.append(key) }
        draft.sshKeyID = key.id
    }

    /// Reads the SSH keys of this device again.
    func loadSSHKeys() {
        guard let keys else { return }
        do {
            sshKeys = try keys.keys()
        } catch {
            Self.logger.error("Could not read the SSH keys: \(error)")
        }
    }

    /// The problem to show for `field`: once the user has left the field, or has tried to save. The
    /// jump hosts' problem shows at once: it is no typing error, and may come from another host.
    func visibleProblem(for field: HostDraft.Field) -> String? {
        if field == .jumpHosts { return jumpHostsProblem }
        guard attemptedSave || leftFields.contains(field) else { return nil }
        return draft.problems[field]
    }

    /// The first field, in the sheet's order, with a problem to show that keeps the host from being
    /// saved.
    var firstProblemField: HostDraft.Field? {
        HostDraft.Field.allCases.first { blockingProblems[$0] != nil && visibleProblem(for: $0) != nil }
    }

    /// The problems to show that keep the host from being saved, in the sheet's order.
    var visibleProblems: [String] {
        HostDraft.Field.allCases.compactMap { blockingProblems[$0] != nil ? visibleProblem(for: $0) : nil }
    }

    /// What keeps the host from being saved, by field: the draft's problems, and a route Shello
    /// refuses through jump hosts the user changed. A route that another host's change broke does
    /// not keep the user from saving the rest; its problem shows all the same.
    private var blockingProblems: [HostDraft.Field: String] {
        var problems = draft.problems
        if draft.jumpHostIDs != original.jumpHostIDs, case .failure(let error)? = route, error.blocksSaving {
            problems[.jumpHosts] = error.editorProblem(editing: routeName)
        }
        return problems
    }

    /// The host's name as it was stored when the editor opened, for confirmations: the draft's may be
    /// half typed.
    var storedName: String { base.name }

    func didLeave(_ field: HostDraft.Field) {
        leftFields.insert(field)
    }

    func isSelected(_ tag: Tag) -> Bool {
        draft.tagIDs.contains(tag.id)
    }

    func toggleTag(_ tag: Tag) {
        if draft.tagIDs.remove(tag.id) == nil {
            draft.tagIDs.insert(tag.id)
        }
    }

    /// Adds a tag to the host: a new one, or the existing tag with that name. Nil for a blank name.
    func addTag(named name: String, color: Tag.Color) -> Tag? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = tags.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            draft.tagIDs.insert(existing.id)
            return existing
        }
        let tag = Tag(name: name, color: color)
        newTags.append(tag)
        draft.tagIDs.insert(tag.id)
        return tag
    }

    /// Puts the host in a group: a new one, or the existing group with that name. Nil for a blank
    /// name.
    func addGroup(named name: String) -> HostGroup? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = groups.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            draft.groupID = existing.id
            return existing
        }
        let group = HostGroup(name: name)
        newGroups.append(group)
        draft.groupID = group.id
        return group
    }

    // MARK: - Jump hosts

    /// One of the draft's jump hosts: the saved host, or nil for one Shello does not have.
    struct JumpHost: Identifiable, Equatable {
        let id: Host.ID
        let host: Host?

        /// Its name, or that it is missing.
        var name: String { host?.name ?? JumpHostDisplay.missingName }
    }

    /// The draft's jump hosts, in order.
    var jumpHosts: [JumpHost] {
        let saved = savedHostsByID
        return draft.jumpHostIDs.map { JumpHost(id: $0, host: saved[$0]) }
    }

    /// The saved SSH hosts the draft can add as a jump host, by name: only SSH hosts can be jump
    /// hosts, a host cannot jump through itself, and each comes once.
    var jumpHostCandidates: [Host] {
        savedHosts.filter { $0.protocol == .ssh && $0.id != base.id && !draft.jumpHostIDs.contains($0.id) }
    }

    /// Adds the host `id` as the last jump host.
    func addJumpHost(_ id: Host.ID) {
        guard !draft.jumpHostIDs.contains(id) else { return }
        draft.jumpHostIDs.append(id)
    }

    func removeJumpHosts(at offsets: IndexSet) {
        draft.jumpHostIDs.remove(atOffsets: offsets)
    }

    func moveJumpHosts(from offsets: IndexSet, to destination: Int) {
        draft.jumpHostIDs.move(fromOffsets: offsets, toOffset: destination)
    }

    /// Moves the jump host at `index` one place up, nearer the device, for an `offset` of -1, or one
    /// place down for 1: what Move Up and Move Down do, where dragging is not possible.
    func moveJumpHost(at index: Int, by offset: Int) {
        let target = index + offset
        guard draft.jumpHostIDs.indices.contains(index), draft.jumpHostIDs.indices.contains(target) else { return }
        draft.jumpHostIDs.swapAt(index, target)
    }

    /// The jump hosts as the editor's row names them: "None", or "bastion → inner".
    var jumpHostsSummary: String {
        jumpHosts.isEmpty ? "None" : JumpHostDisplay.shown(jumpHosts.map(\.name))
    }

    /// `jumpHostsSummary` as VoiceOver reads it: "bastion, then inner".
    var spokenJumpHostsSummary: String {
        jumpHosts.isEmpty ? "None" : JumpHostDisplay.spoken(jumpHosts.map(\.name))
    }

    /// The draft's route through the saved jump hosts, or why Shello would refuse it; nil without
    /// jump hosts. The route to the first jump host comes first, through that host's own jump
    /// hosts, as when connecting (`Route`).
    var route: Result<Route, RouteError>? {
        guard !draft.jumpHostIDs.isEmpty else { return nil }
        var host = base
        host.name = routeName
        host.protocol = draft.protocol
        host.jumpHostIDs = draft.jumpHostIDs
        var hosts = savedHostsByID
        // A jump host's route that comes back here comes back to the draft.
        hosts[base.id] = host
        return Result { () throws(RouteError) -> Route in try Route(to: host, hosts: hosts) }
    }

    /// The problem with the jump hosts, under their row: a route Shello refuses, or a jump host it
    /// does not have.
    var jumpHostsProblem: String? {
        guard case .failure(let error)? = route else { return nil }
        return error.editorProblem(editing: routeName)
    }

    /// The other saved hosts that connect through this one, whose routes its deletion would leave
    /// with a missing jump host, by name.
    var hostsJumpingThrough: [Host] {
        Route.hosts(jumpingThrough: base.id, among: savedHosts)
    }

    /// The host's name as the route's problems use it.
    private var routeName: String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "this host" : name
    }

    private var savedHostsByID: [Host.ID: Host] {
        Dictionary(savedHosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Follows the saved hosts, for the jump hosts, until the task is cancelled.
    func observeSavedHosts() async {
        do {
            for try await hosts in repository.observeHosts() {
                savedHosts = hosts
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("Could not read the hosts: \(error)")
        }
    }

    /// Follows the stored groups and tags until the task is cancelled.
    func observeGroupsAndTags() async {
        async let groups: Void = observeGroups()
        async let tags: Void = observeTags()
        _ = await (groups, tags)
    }

    /// Stores the host, with the new group and tags it uses, and its password in the Keychain.
    /// Returns false if the draft has a problem, which is then shown, or if storing fails.
    ///
    /// A typed password is stored first, so that nothing is saved if the Keychain refuses it. If the
    /// host then cannot be stored, a new host's password goes again; an existing host keeps the new
    /// one, which saving again stores once more. A stored password that the user removed, or that
    /// the host's method no longer uses, goes once the host is saved.
    func save() async -> Bool {
        attemptedSave = true
        guard blockingProblems.isEmpty else { return false }
        guard hasChanges || !isEditing else { return true }
        let passwordID = SecretID.password(of: base.id)
        let storesPassword = offersPassword && !password.isEmpty
        do {
            if storesPassword {
                try secrets?.store(Secret(utf8: password), as: passwordID)
            }
            guard try await saveHost() else {
                // Its password went with it, and must not come back.
                if storesPassword { discardPassword(passwordID) }
                saveError = "This host was deleted while you were editing it."
                return false
            }
        } catch {
            // A host that is not stored has no use for a password.
            if storesPassword, !isEditing { discardPassword(passwordID) }
            Self.logger.error("Could not save a host: \(error)")
            saveError = String(describing: error)
            return false
        }
        password = ""
        if storesPassword {
            hasStoredPassword = true
            removesStoredPassword = false
        } else if hasStoredPassword, removesStoredPassword || draft.authMethod != .password {
            do {
                try secrets?.remove(passwordID)
                hasStoredPassword = false
                removesStoredPassword = false
            } catch {
                Self.logger.error("Could not remove a host's password: \(error)")
                saveError = "The host is saved, but its saved password could not be removed. \(error)"
                return false
            }
        }
        return true
    }

    /// Deletes the host being edited, and its password. The repository keeps a tombstone (README
    /// section 15).
    func delete() async -> Bool {
        do {
            try await repository.deleteHost(id: base.id, removingSecretsFrom: secrets)
            return true
        } catch {
            Self.logger.error("Could not delete a host: \(error)")
            saveError = String(describing: error)
            return false
        }
    }

    /// Stores the host and the new group and tags it uses. Returns false if the host was deleted
    /// while the editor was open.
    private func saveHost() async throws -> Bool {
        try await storeNewGroupAndTags()
        if isEditing {
            // Apply the user's changes to the host as it is stored now, not as it was read.
            guard let stored = try await repository.host(id: base.id) else { return false }
            try await repository.update(draft.applied(to: stored, comparedTo: original))
        } else {
            try await repository.create(draft.applied(to: base, comparedTo: original))
        }
        return true
    }

    /// Removes a password that this editor stored for a host that does not exist.
    private func discardPassword(_ id: SecretID) {
        do {
            try secrets?.remove(id)
        } catch {
            Self.logger.error("Could not remove the password of a host that was not saved: \(error)")
        }
    }

    /// Stores the groups and tags created in this editor that the host uses. Each one is stored
    /// once, even if saving the host fails and the user saves again.
    private func storeNewGroupAndTags() async throws {
        for group in newGroups where group.id == draft.groupID {
            try await repository.create(group)
            newGroups.removeAll { $0.id == group.id }
            if !storedGroups.contains(where: { $0.id == group.id }) { storedGroups.append(group) }
        }
        for tag in newTags where draft.tagIDs.contains(tag.id) {
            try await repository.create(tag)
            newTags.removeAll { $0.id == tag.id }
            if !storedTags.contains(where: { $0.id == tag.id }) { storedTags.append(tag) }
        }
    }

    private func observeGroups() async {
        do {
            for try await groups in repository.observeGroups() {
                storedGroups = groups
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("Could not read the groups: \(error)")
        }
    }

    private func observeTags() async {
        do {
            for try await tags in repository.observeTags() {
                storedTags = tags
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("Could not read the tags: \(error)")
        }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "HostEditor")
}
