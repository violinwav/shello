import Foundation
import Observation
import ShelloModel
import ShelloSecurity
import ShelloStorage
import os

/// One host's details, with the names of its group and tags. It follows the database, so the
/// details update as soon as the host changes, and say so once it is deleted.
@Observable
final class HostDetailModel {
    let repository: HostRepository
    /// The Keychain's secrets, which go with the host when it is deleted.
    let secrets: SecretStore?
    let hostID: Host.ID
    /// Set when a change the user asked for fails; the screen shows it and clears it.
    var actionError: String?

    private(set) var host: Host?
    private var groups: [HostGroup] = []
    private var tags: [Tag] = []
    private var hasLoaded = false

    init(repository: HostRepository, secrets: SecretStore? = nil, hostID: Host.ID) {
        self.repository = repository
        self.secrets = secrets
        self.hostID = hostID
    }

    /// Whether the host does not exist, or no longer does.
    var isGone: Bool { hasLoaded && host == nil }

    var groupName: String? {
        host?.groupID.flatMap { id in groups.first { $0.id == id }?.name }
    }

    /// The host's tags, by name.
    var hostTags: [Tag] {
        guard let host else { return [] }
        return tags.filter { host.tagIDs.contains($0.id) }
    }

    /// Follows the host, the groups and the tags until the task is cancelled.
    func observe() async {
        async let host: Void = observeHost()
        async let groups: Void = observeGroups()
        async let tags: Void = observeTags()
        _ = await (host, groups, tags)
    }

    /// Connects to the host. A stub that does nothing: connections and terminal tabs come in #28.
    func connect() {}

    /// Marks or unmarks the host as a favourite, and returns whether it worked.
    @discardableResult
    func setFavorite(_ isFavorite: Bool) async -> Bool {
        do {
            try await repository.setFavorite(isFavorite, hostID: hostID)
            return true
        } catch {
            Self.logger.error("Could not change a favourite: \(error)")
            actionError = String(describing: error)
            return false
        }
    }

    /// Deletes the host and its password. The repository keeps a tombstone (README section 15).
    func delete() async -> Bool {
        do {
            try await repository.deleteHost(id: hostID, removingSecretsFrom: secrets)
            return true
        } catch {
            Self.logger.error("Could not delete a host: \(error)")
            actionError = String(describing: error)
            return false
        }
    }

    private func observeHost() async {
        do {
            for try await host in repository.observeHost(id: hostID) {
                self.host = host
                hasLoaded = true
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("Could not read a host: \(error)")
            actionError = String(describing: error)
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

extension HostRepository {
    /// Marks or unmarks a host as a favourite. Only the flag changes, on the host as it is stored
    /// now, so that the write never undoes a change the screen has not shown yet.
    func setFavorite(_ isFavorite: Bool, hostID: Host.ID) async throws {
        guard var stored = try await host(id: hostID) else {
            throw HostRepositoryError.hostNotFound(hostID)
        }
        stored.isFavorite = isFavorite
        try await update(stored)
    }

    /// Deletes a host and its secrets (README section 13). The secrets go first: if writing the
    /// tombstone then fails, a host the user wanted gone is left without its password, rather than a
    /// password without its host.
    func deleteHost(id: Host.ID, removingSecretsFrom secrets: SecretStore?) async throws {
        try secrets?.removeSecrets(ofHost: id)
        try await deleteHost(id: id)
    }
}
