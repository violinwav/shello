import ShelloCore
import ShelloModel
import ShelloTerminalUI
import SwiftUI

/// The host list (README section 3): search, tag filters, the window's open tabs under Live, and
/// sections for favourites, recents and groups. Each host's row opens the host's details; each
/// tab's row shows the tab on the terminal screen.
struct HostListView: View {
    @Bindable var model: HostListModel
    /// The selected host in a split view. Nil in a navigation stack, where a row pushes the details.
    var selection: Binding<Host.ID?>?

    @State private var editorRoute: EditorRoute?
    @State private var showsSettings = false
    @State private var hostToDelete: Host?
    @Environment(TerminalTabsModel.self) private var tabs: TerminalTabsModel?

    var body: some View {
        list
            // On the list only: toolbar items and sheets keep the system font, which follows Dynamic Type.
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .overlay { emptyState }
            .navigationTitle("Hosts")
            .searchable(text: $model.searchText, prompt: "Search hosts, tags, IPs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { editorRoute = EditorRoute(host: nil) }
                        .keyboardShortcut("n")
                }
            }
            .task { await model.observeGroupsAndTags() }
            .task(id: model.searchText) { await model.observeHosts(matching: model.searchText) }
            // A search or a filter that empties the list says so, after VoiceOver has read what was
            // typed or tapped.
            .onChange(of: model.emptyState) { _, state in
                switch state {
                case .noSearchResults(let search): announce("No results for \(search)", priority: .low)
                case .noHostsWithTag(let tag): announce("No hosts tagged \(tag)", priority: .low)
                case .noHosts, nil: break
                }
            }
            .sheet(item: $editorRoute) { route in
                HostEditorView(repository: model.repository, secrets: model.secrets, keys: model.keys, host: route.host)
            }
            .sheet(isPresented: $showsSettings) { SettingsView() }
            .confirmationDialog(
                hostToDelete.map { "Delete “\($0.name)”?" } ?? "",
                isPresented: isPresented($hostToDelete),
                titleVisibility: .visible,
                presenting: hostToDelete
            ) { host in
                Button("Delete Host", role: .destructive) {
                    Task {
                        if await model.delete(host) { announce("Deleted \(host.name)") }
                    }
                }
            } message: { _ in
                Text("This removes the host from Shello.")
            }
            .alert("Couldn’t Change the Host", isPresented: isPresented($model.actionError)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
    }

    @ViewBuilder private var list: some View {
        if let selection {
            List(selection: selection) { content }
        } else {
            List { content }
        }
    }

    @ViewBuilder private var content: some View {
        if !model.tags.isEmpty {
            Section {
                TagFilterBar(tags: model.tags, selection: $model.tagFilter)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        if let tabs, !tabs.tabs.tabs.isEmpty {
            Section {
                ForEach(tabs.tabs.tabs) { tab in
                    LiveTabRow(tab: tab, name: tabs.name(of: tab)) { tabs.show(tab) }
                        .listRowBackground(Palette.cell)
                }
            } header: {
                SectionHeader("Live")
            }
        }
        ForEach(model.sections) { section in
            Section {
                ForEach(section.hosts) { host in
                    row(host)
                }
            } header: {
                SectionHeader(section.title)
            }
        }
    }

    private func row(_ host: Host) -> some View {
        let tags = model.tags(of: host)
        return NavigationLink(value: host.id) {
            HostRow(host: host, tags: tags)
        }
        .accessibilityLabel(host.name)
        .accessibilityValue(HostRow.accessibilityValue(of: host, tags: tags))
        .listRowBackground(Palette.cell)
        // Swipe actions draw white on their tint: the deep accent keeps 7.3:1 in both appearances.
        .swipeActions(edge: .leading) {
            favoriteButton(host)
                .tint(Palette.accentDeep)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { hostToDelete = host }
            Button("Edit", systemImage: "pencil") { editorRoute = EditorRoute(host: host) }
                .tint(Palette.accentDeep)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editorRoute = EditorRoute(host: host) }
            favoriteButton(host)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { hostToDelete = host }
        }
    }

    private func favoriteButton(_ host: Host) -> some View {
        Button(
            host.isFavorite ? "Remove from Favorites" : "Add to Favorites",
            systemImage: host.isFavorite ? "star.slash" : "star"
        ) {
            Task {
                if await model.setFavorite(!host.isFavorite, for: host) {
                    announce(
                        host.isFavorite ? "Removed \(host.name) from Favorites" : "Added \(host.name) to Favorites")
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if let loadError = model.loadError {
            EmptyStateView(
                title: "Couldn’t Read the Hosts", systemImage: "exclamationmark.triangle", description: loadError)
        } else {
            switch model.emptyState {
            case .noHosts:
                EmptyStateView(
                    title: "No Hosts", systemImage: "server.rack",
                    description: "A host holds everything Shello needs to reach a server."
                ) {
                    Button("Add Host") { editorRoute = EditorRoute(host: nil) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accentFill()
                }
            case .noSearchResults(let search):
                EmptyStateView(
                    title: "No Results for “\(search)”", systemImage: "magnifyingglass",
                    description: "Search looks at names, addresses, users and tags.")
            case .noHostsWithTag(let tag):
                EmptyStateView(
                    title: "No Hosts Tagged \(tag)", systemImage: "tag", description: "Choose All to see every host.")
            case nil:
                EmptyView()
            }
        }
    }

    /// A binding that says whether `value` is set, for presenting it; dismissing clears it.
    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// The host the editor sheet opens for, or nil for a new host.
struct EditorRoute: Identifiable {
    let id = UUID()
    let host: Host?
}

/// An open tab under Live: how its connection is, its name, and its protocol with its latency, or
/// what its connection does. A tap shows it on the terminal screen.
private struct LiveTabRow: View {
    let tab: TerminalTab<TerminalController>
    let name: String
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(spacing: 12) {
                TabStatusSymbol(state: tab.state)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(summary)
                        .font(Typography.dataCaption)
                        .foregroundStyle(Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(TabStatusSymbol.spokenStatus(of: tab, name: name))
    }

    /// "ssh · 24 ms" while the connection works, or what it does.
    private var summary: String {
        switch tab.state {
        case .active: (["ssh"] + (tab.latency.map { [$0.latencyText] } ?? [])).joined(separator: " · ")
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .suspended: "Disconnected in the background"
        case .ended: "Connection closed"
        case .disconnected: "Disconnected"
        case .closed: "Closed"
        }
    }
}
