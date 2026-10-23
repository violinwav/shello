import Foundation
import Observation
import ShelloCore
import ShelloModel
import ShelloSecurity

/// Installing an SSH key on a host (README section 13), from the key's details: the hosts of the
/// window's tabs whose connection is open, one row each, and what installing the key did on each.
/// Shello installs over a connection that is open, so a host without one is not offered.
@Observable
final class InstallSSHKeyModel {
    /// A host that a tab is connected to, which the key can be installed on.
    struct Target: Identifiable {
        let host: Host
        /// Installs the key over the tab's connection.
        let install: @MainActor (SSHKey) async throws -> KeyInstallation

        var id: Host.ID { host.id }
    }

    /// What installing the key on a host did, or does.
    enum Outcome: Hashable {
        case installing
        case installed(KeyInstallation)
        case failed(String)
    }

    let key: SSHKey
    private let targets: @MainActor () -> [Target]
    /// What installing did on each host it was tried on.
    private(set) var outcomes: [Host.ID: Outcome] = [:]
    /// The host the key was last installed on, whose outcome the sheet says.
    private(set) var lastHost: Host?

    /// Installs `key` on the hosts `targets` lists, as it lists them each time.
    init(key: SSHKey, targets: @escaping @MainActor () -> [Target]) {
        self.key = key
        self.targets = targets
    }

    /// The hosts of `tabs` with a connection that is open, in the tabs' order, each once.
    convenience init(key: SSHKey, tabs: TerminalTabsModel?) {
        self.init(key: key) {
            var seen = Set<Host.ID>()
            return (tabs?.tabs.tabs ?? []).compactMap { tab in
                guard tab.state == .active, seen.insert(tab.host.id).inserted else { return nil }
                return Target(host: tab.host) { [weak tab] key in
                    guard let tab else { throw KeyInstallationError.notConnected }
                    return try await tab.installSSHKey(key)
                }
            }
        }
    }

    /// The hosts the key can be installed on now.
    var hosts: [Target] { targets() }

    /// Whether the key is being installed somewhere.
    var isInstalling: Bool { outcomes.values.contains(.installing) }

    /// Installs the key on `target`'s host, once nothing else is being installed.
    func install(on target: Target) async {
        guard !isInstalling else { return }
        outcomes[target.id] = .installing
        lastHost = target.host
        do {
            outcomes[target.id] = .installed(try await target.install(key))
        } catch {
            SSHKeyListModel.logger.error("Could not install an SSH key: \(error)")
            outcomes[target.id] = .failed(String(describing: error))
        }
    }

    /// What the last installing did, in a sentence, once it is done.
    var lastResult: String? {
        guard let host = lastHost, let outcome = outcomes[host.id] else { return nil }
        return Self.sentence(for: outcome, on: host)
    }

    static func sentence(for outcome: Outcome, on host: Host) -> String? {
        switch outcome {
        case .installing: nil
        case .installed(.added): "Installed on \(host.name): the key is in ~/.ssh/authorized_keys now."
        case .installed(.alreadyInstalled): "\(host.name) has the key already. Nothing changed."
        case .failed(let reason): "Couldn’t install on \(host.name). \(reason)"
        }
    }
}
