import Foundation
import Observation
import ShelloModel
import ShelloSecurity
import ShelloStorage
import os

/// The host list: the hosts that match the search, in sections, with the groups and tags they
/// refer to. It follows the database, so the list updates as soon as anything changes.
@Observable
final class HostListModel {
    /// Why the list has nothing to show.
    enum EmptyState: Equatable {
        case noHosts
        case noSearchResults(String)
        case noHostsWithTag(String)
    }

    let repository: HostRepository
    /// The Keychain's secrets, which go with a host when it is deleted.
    let secrets: SecretStore?
    /// The SSH keys on this device, which the host editor offers.
    let keys: SSHKeyStore?

    /// What the user typed into the search field. The screen observes the hosts again with
    /// `observeHosts(matching:)` whenever it changes.
    var searchText = ""
    /// The tag a host must have to be listed, or nil for every host.
    var tagFilter: Tag.ID?
    /// Set when a change the user asked for fails; the screen shows it and clears it.
    var actionError: String?

    /// The hosts that match the search, by name.
    private(set) var hosts: [Host] = []
    /// The search `hosts` matches.
    private(set) var hostsSearch = ""
    private(set) var groups: [HostGroup] = []
    /// Every tag, by name: the tag filters.
    private(set) var tags: [Tag] = []
    /// Whether the first hosts have arrived, so that an empty list really is empty.
    private(set) var hasLoaded = false
    /// Set when the hosts cannot be read.
    private(set) var loadError: String?

    init(repository: HostRepository, secrets: SecretStore? = nil, keys: SSHKeyStore? = nil) {
        self.repository = repository
        self.secrets = secrets
        self.keys = keys
    }

    /// The tag filter, unless its tag no longer exists.
    var activeTagFilter: Tag.ID? {
        tagFilter.flatMap { id in tags.contains { $0.id == id } ? id : nil }
    }

    var sections: [HostSection] {
        HostSection.sections(hosts: hosts, groups: groups, tagFilter: activeTagFilter)
    }

    var emptyState: EmptyState? {
        guard hasLoaded else { return nil }
        if hosts.isEmpty {
            return hostsSearch.isEmpty ? .noHosts : .noSearchResults(hostsSearch)
        }
        if sections.isEmpty, let tag = tags.first(where: { $0.id == activeTagFilter }) {
            return .noHostsWithTag(tag.name)
        }
        return nil
    }

    /// The host's tags, by name.
    func tags(of host: Host) -> [Tag] {
        tags.filter { host.tagIDs.contains($0.id) }
    }

    /// Follows the hosts that match `search` until the task is cancelled.
    func observeHosts(matching search: String) async {
        do {
            for try await hosts in repository.observeHosts(HostQuery(search: search, order: .name)) {
                self.hosts = hosts
                hostsSearch = search
                hasLoaded = true
                loadError = nil
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("Could not read the hosts: \(error)")
            loadError = String(describing: error)
        }
    }

    /// Follows the groups and the tags until the task is cancelled.
    func observeGroupsAndTags() async {
        async let groups: Void = observeGroups()
        async let tags: Void = observeTags()
        _ = await (groups, tags)
    }

    /// Marks or unmarks a host as a favourite, leaving its other fields as they are stored. Returns
    /// whether it worked.
    @discardableResult
    func setFavorite(_ isFavorite: Bool, for host: Host) async -> Bool {
        do {
            try await repository.setFavorite(isFavorite, hostID: host.id)
            return true
        } catch {
            Self.logger.error("Could not change a favourite: \(error)")
            actionError = String(describing: error)
            return false
        }
    }

    /// The other saved hosts that connect through `host`, by name, whose routes its deletion would
    /// leave with a missing jump host (README section 3): for the confirmation, which names them.
    func hostsJumping(through host: Host) async -> [Host] {
        do {
            return Route.hosts(jumpingThrough: host.id, among: try await repository.hosts())
        } catch {
            Self.logger.error("Could not read the hosts: \(error)")
            return []
        }
    }

    /// Deletes a host and its password, and returns whether it worked. The repository keeps a
    /// tombstone (README section 15), so that sync can carry the deletion later.
    @discardableResult
    func delete(_ host: Host) async -> Bool {
        do {
            try await repository.deleteHost(id: host.id, removingSecretsFrom: secrets)
            return true
        } catch {
            Self.logger.error("Could not delete a host: \(error)")
            actionError = String(describing: error)
            return false
        }
    }

    private func observeGroups() async {
        do {
            for try await groups in repository.observeGroups() {
                self.groups = groups
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("Could not read the groups: \(error)")
        }
    }

    private func observeTags() async {
        do {
            for try await tags in repository.observeTags() {
                self.tags = tags
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("Could not read the tags: \(error)")
        }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Hosts")
}
