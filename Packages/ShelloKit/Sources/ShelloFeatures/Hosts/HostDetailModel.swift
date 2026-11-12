import Foundation
import Observation
import ShelloModel
import ShelloSecurity
import ShelloStorage
import os

/// One host's details, with the names of its group, tags and SSH key, and its route through its jump
/// hosts (README section 3). It follows the database, so the details update as soon as the host,
/// or one it jumps through, changes, and say so once it is deleted.
@Observable
final class HostDetailModel {
    let repository: HostRepository
    /// The Keychain's secrets, which go with the host when it is deleted.
    let secrets: SecretStore?
    /// The SSH keys on this device, which name the host's SSH key.
    let keys: SSHKeyStore?
    let hostID: Host.ID
    /// Set when a change the user asked for fails; the screen shows it and clears it.
    var actionError: String?

    private(set) var host: Host?
    private var groups: [HostGroup] = []
    private var tags: [Tag] = []
    private var sshKeys: [SSHKey] = []
    /// The saved hosts, among which the jump hosts are looked up.
    private var savedHosts: [Host] = []
    private var hasLoaded = false

    init(repository: HostRepository, secrets: SecretStore? = nil, keys: SSHKeyStore? = nil, hostID: Host.ID) {
        self.repository = repository
        self.secrets = secrets
        self.keys = keys
        self.hostID = hostID
        loadSSHKeys()
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

    /// The host's SSH key, by name: "None", or "Not on this device" for a key made on another device
    /// or deleted since (README section 15).
    var sshKeySummary: String {
        guard let id = host?.sshKeyID else { return "None" }
        return sshKeys.first { $0.id == id }?.comment ?? "Not on this device"
    }

    // MARK: - Route

    /// The host's route through its jump hosts as they are saved now, or why Shello refuses it.
    var route: Result<Route, RouteError>? {
        guard let host else { return nil }
        let saved = Dictionary(savedHosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Result { () throws(RouteError) -> Route in try Route(to: host, hosts: saved) }
    }

    /// The route as the details show it: "Direct" for a host without jump hosts, or the hosts in
    /// order, "bastion → web-01". One Shello refuses shows the host's own jump hosts, a missing one
    /// named so.
    var routeSummary: String {
        routeNames.map(JumpHostDisplay.shown) ?? "Direct"
    }

    /// `routeSummary` as VoiceOver reads it: "bastion, then web-01".
    var spokenRouteSummary: String {
        routeNames.map(JumpHostDisplay.spoken) ?? "Direct"
    }

    /// Why Shello does not connect along the route, under it.
    var routeProblem: String? {
        guard let host, case .failure(let error)? = route else { return nil }
        return error.detailProblem(of: host.name)
    }

    /// The other saved hosts that connect through this one, whose routes its deletion would leave
    /// with a missing jump host, by name.
    var hostsJumpingThrough: [Host] {
        Route.hosts(jumpingThrough: hostID, among: savedHosts)
    }

    /// The names along the route, or nil for a host without jump hosts.
    private var routeNames: [String]? {
        guard let host, !host.jumpHostIDs.isEmpty else { return nil }
        if case .success(let route)? = route {
            return route.hops.map(\.name)
        }
        let saved = Dictionary(savedHosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return JumpHostDisplay.names(of: host.jumpHostIDs, among: saved) + [host.name]
    }

    /// Reads the SSH keys of this device again: the Keychain tells nobody when they change.
    func loadSSHKeys() {
        guard let keys else { return }
        do {
            sshKeys = try keys.keys()
        } catch {
            Self.logger.error("Could not read the SSH keys: \(error)")
        }
    }

    /// Follows the host, the groups, the tags and the hosts it may jump through until the task is
    /// cancelled.
    func observe() async {
        async let host: Void = observeHost()
        async let groups: Void = observeGroups()
        async let tags: Void = observeTags()
        async let hosts: Void = observeSavedHosts()
        _ = await (host, groups, tags, hosts)
    }

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

    private func observeSavedHosts() async {
        do {
            for try await hosts in repository.observeHosts() {
                savedHosts = hosts
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("Could not read the hosts: \(error)")
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
