import ShelloModel
import ShelloStorage
import SwiftUI
import UIKit

/// The app's first screen: the host list. It takes the hosts from the environment's
/// `hostRepository`, which the composition root sets.
public struct RootView: View {
    @Environment(\.hostRepository) private var repository

    public init() {}

    public var body: some View {
        Group {
            if let repository {
                HostsScreen(repository: repository)
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
/// onto a navigation stack on iPhone (STACK section 7.13).
struct HostsScreen: View {
    @State private var model: HostListModel
    @State private var selection: Host.ID?
    @State private var path: [Host.ID] = []

    init(repository: HostRepository) {
        _model = State(initialValue: HostListModel(repository: repository))
    }

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView {
                HostListView(model: model, selection: $selection)
            } detail: {
                if let selection {
                    HostDetailView(repository: model.repository, hostID: selection) {
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
                        HostDetailView(repository: model.repository, hostID: hostID) {
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
