import ShelloCore
import ShelloModel
import ShelloSecurity
import ShelloStorage
import SwiftUI
import UIKit

/// The app's first screen: the host list. It takes the hosts from the environment's
/// `hostRepository`, their passwords from its `secretStore`, the SSH keys to choose from its
/// `sshKeyStore`, and connects with its `hostConnector`, which the composition root sets.
public struct RootView: View {
    @Environment(\.hostRepository) private var repository
    @Environment(\.secretStore) private var secrets
    @Environment(\.sshKeyStore) private var keys
    @Environment(\.hostConnector) private var connector
    @Environment(\.terminalSettings) private var terminalSettings
    @Environment(\.hardwareKeyboard) private var hardwareKeyboard
    @Environment(\.backgroundConnectionTime) private var backgroundConnectionTime
    @Environment(\.rememberedTabs) private var rememberedTabs

    public init() {}

    public var body: some View {
        Group {
            if let repository {
                HostsScreen(
                    repository: repository, secrets: secrets, keys: keys,
                    tabs: connector.map {
                        TerminalTabsModel(
                            connector: $0, hosts: repository, settings: terminalSettings,
                            hardwareKeyboard: hardwareKeyboard, rememberedTabs: rememberedTabs,
                            backgroundTime: backgroundConnectionTime)
                    })
            } else {
                EmptyStateView(
                    title: "Hosts Unavailable", systemImage: "externaldrive.badge.exclamationmark",
                    description: "Shello started without its database.")
            }
        }
        // The screens set their fonts on their content: toolbar items, alerts and system controls
        // keep the system font, which they scale with Dynamic Type themselves.
        .tint(Palette.accentInk)
    }
}

/// The host list with the selected host's details: side by side in a split view on iPad, pushed
/// onto a navigation stack on iPhone (STACK section 7.13). The window's tabs show over it, on the
/// terminal screen, and follow the window's foreground and background, and app lock. They are
/// remembered under the window's scene session, for Restore (GLOSSARY).
struct HostsScreen: View {
    @State private var model: HostListModel
    @State private var tabs: TerminalTabsModel?
    @State private var selection: Host.ID?
    @State private var path: [Host.ID] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appLock) private var appLock

    /// The host list of `repository`, whose hosts connect in `tabs`, a window's own; without them,
    /// they cannot connect.
    init(repository: HostRepository, secrets: SecretStore?, keys: SSHKeyStore?, tabs: TerminalTabsModel? = nil) {
        _model = State(initialValue: HostListModel(repository: repository, secrets: secrets, keys: keys))
        _tabs = State(initialValue: tabs)
    }

    var body: some View {
        hosts
            .environment(tabs)
            .background {
                WindowReader { window in
                    guard let session = window.windowScene?.session else { return }
                    tabs?.windowAppeared(session.persistentIdentifier)
                }
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { tabs?.isShowingTerminals ?? false }, set: { tabs?.isShowingTerminals = $0 })
            ) {
                if let tabs {
                    TerminalTabsView(model: tabs)
                }
            }
            // The terminal screen's tabs and terminal, for the shortcuts, from here: the commands
            // do not see what views in a full-screen cover publish.
            .focusedSceneValue(\.terminalTabs, showsTerminals ? tabs : nil)
            .focusedSceneValue(\.terminal, showsTerminals ? tabs?.selectedTab?.terminal : nil)
            .onChange(of: scenePhase, initial: true) { _, phase in
                tabs?.scenePhaseChanged(phase)
            }
            .onChange(of: appLock?.isLocked ?? false, initial: true) { _, isLocked in
                tabs?.lockChanged(isLocked: isLocked)
            }
    }

    private var showsTerminals: Bool { tabs?.isShowingTerminals ?? false }

    @ViewBuilder private var hosts: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView {
                HostListView(model: model, selection: $selection)
            } detail: {
                if let selection {
                    HostDetailView(
                        repository: model.repository, secrets: model.secrets, keys: model.keys, hostID: selection
                    ) {
                        self.selection = nil
                    }
                    .id(selection)
                } else {
                    EmptyStateView(
                        title: "No Host Selected", systemImage: "server.rack",
                        description: "Choose a host to see its details."
                    )
                    .background(Palette.ground)
                }
            }
        } else {
            NavigationStack(path: $path) {
                HostListView(model: model, selection: nil)
                    .navigationDestination(for: Host.ID.self) { hostID in
                        HostDetailView(
                            repository: model.repository, secrets: model.secrets, keys: model.keys, hostID: hostID
                        ) {
                            path.removeAll { $0 == hostID }
                        }
                    }
            }
        }
    }
}

#Preview {
    RootView()
        .environment(
            \.hostRepository,
            try? HostRepository(AppDatabase(directory: .temporaryDirectory.appending(path: UUID().uuidString))))
}
