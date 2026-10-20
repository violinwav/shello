import Foundation
import Observation
import ShelloModel
import ShelloStorage
import os

/// The new and edit host sheet: a draft of every MVP field, the groups and tags to choose from, and
/// the groups and tags created on the way, which are stored only with the host.
@Observable
final class HostEditorModel {
    let repository: HostRepository
    var draft: HostDraft
    /// Set when saving or deleting fails; the sheet shows it and clears it.
    var saveError: String?

    /// The host as it was read when the editor opened, or a new host's defaults.
    private let base: Host
    private let original: HostDraft
    let isEditing: Bool

    private var storedGroups: [HostGroup] = []
    private var storedTags: [Tag] = []
    /// Groups and tags created in this editor and not stored yet.
    private var newGroups: [HostGroup] = []
    private var newTags: [Tag] = []

    private var attemptedSave = false
    private var leftFields: Set<HostDraft.Field> = []

    /// An editor for `host` as the caller last read it, or for a new host.
    init(repository: HostRepository, host: Host?) {
        self.repository = repository
        isEditing = host != nil
        base = host ?? Host(name: "", address: "", username: "")
        original = HostDraft(base)
        draft = original
    }

    var title: String { isEditing ? "Edit Host" : "New Host" }

    /// Whether closing the editor would lose anything the user entered.
    var hasChanges: Bool { draft != original }

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

    /// The host's SSH key. Keys cannot be created or imported yet, so a key a host refers to, for
    /// example after an import, is on another device (README section 15).
    var sshKeySummary: String {
        base.sshKeyID == nil ? "None" : "Not on this device"
    }

    /// The problem to show for `field`: once the user has left the field, or has tried to save.
    func visibleProblem(for field: HostDraft.Field) -> String? {
        guard attemptedSave || leftFields.contains(field) else { return nil }
        return draft.problems[field]
    }

    /// The first field, in the sheet's order, with a problem to show.
    var firstProblemField: HostDraft.Field? {
        HostDraft.Field.allCases.first { visibleProblem(for: $0) != nil }
    }

    /// The problems to show, in the sheet's order.
    var visibleProblems: [String] {
        HostDraft.Field.allCases.compactMap(visibleProblem(for:))
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

    /// Follows the stored groups and tags until the task is cancelled.
    func observeGroupsAndTags() async {
        async let groups: Void = observeGroups()
        async let tags: Void = observeTags()
        _ = await (groups, tags)
    }

    /// Stores the host, with the new group and tags it uses. Returns false if the draft has a
    /// problem, which is then shown, or if storing fails.
    func save() async -> Bool {
        attemptedSave = true
        guard draft.problems.isEmpty else { return false }
        guard hasChanges || !isEditing else { return true }
        do {
            try await storeNewGroupAndTags()
            if isEditing {
                // Apply the user's changes to the host as it is stored now, not as it was read.
                guard let stored = try await repository.host(id: base.id) else {
                    saveError = "This host was deleted while you were editing it."
                    return false
                }
                try await repository.update(draft.applied(to: stored, comparedTo: original))
            } else {
                try await repository.create(draft.applied(to: base, comparedTo: original))
            }
            return true
        } catch {
            Self.logger.error("Could not save a host: \(error)")
            saveError = String(describing: error)
            return false
        }
    }

    /// Deletes the host being edited. The repository keeps a tombstone (README section 15).
    func delete() async -> Bool {
        do {
            try await repository.deleteHost(id: base.id)
            return true
        } catch {
            Self.logger.error("Could not delete a host: \(error)")
            saveError = String(describing: error)
            return false
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
