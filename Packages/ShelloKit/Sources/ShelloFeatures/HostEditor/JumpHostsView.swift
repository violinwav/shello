import ShelloModel
import SwiftUI

/// The host editor's jump hosts (README section 3): the saved SSH hosts Shello connects through to
/// reach the host, in order, the first one from this device. Add Jump Host chooses among the saved
/// SSH hosts. A jump host is removed with a swipe, its menu or VoiceOver's actions. Reordering never
/// needs a drag: while Reorder is on, each row has Move Up and Move Down buttons beside its handle,
/// for Voice Control, Switch Control and everyone else, and VoiceOver and Switch Control also offer
/// the moves as the row's actions, as its menu, a long press away, does.
struct JumpHostsView: View {
    let model: HostEditorModel
    @State private var editMode = EditMode.inactive
    /// The jump host VoiceOver and Switch Control stay on once one of its actions moved it.
    @AccessibilityFocusState private var focusedJumpHost: Host.ID?

    var body: some View {
        let jumpHosts = model.jumpHosts
        List {
            Section {
                ForEach(Array(jumpHosts.enumerated()), id: \.element.id) { index, jumpHost in
                    row(jumpHost, at: index, of: jumpHosts.count)
                }
                .onMove { model.moveJumpHosts(from: $0, to: $1) }
                if let problem = model.jumpHostsProblem {
                    // Under the jump hosts, before the footer. In a list, a long problem would wrap
                    // under its icon.
                    ProblemText(problem: problem)
                        .labelStyle(.row)
                }
                // Reorder turns links off, and dims them: Done brings it back.
                if !editMode.isEditing {
                    NavigationLink {
                        JumpHostPicker(model: model)
                    } label: {
                        Label("Add Jump Host…", systemImage: "plus")
                            .labelStyle(.row)
                            .foregroundStyle(Palette.accentInk)
                    }
                }
            } header: {
                SectionHeader("Jump Hosts")
            } footer: {
                FooterText(footer)
                    .accessibilityLabel(spokenFooter)
            }
            .listRowBackground(Palette.cell)
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Jump Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if jumpHosts.count > 1 || editMode.isEditing {
                ToolbarItem(placement: .primaryAction) {
                    Button(
                        editMode.isEditing ? "Done" : "Reorder",
                        systemImage: editMode.isEditing ? "checkmark" : "arrow.up.arrow.down"
                    ) {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                    // For Voice Control: the toolbar shows only the symbol.
                    .accessibilityInputLabels(editMode.isEditing ? ["Done"] : ["Reorder", "Move", "Sort"])
                }
            }
        }
        // A move, a removal or a new jump host can make a route that Shello refuses, which is said
        // after what the change itself announces.
        .onChange(of: model.jumpHostsProblem) { old, new in
            if let new, new != old { announce(new, priority: .low) }
        }
        .environment(\.editMode, $editMode)
        // A link's destination takes the font of the list the link is in, the editor's here.
        .environment(\.font, nil)
    }

    /// A jump host, by its place on the way: its name, and how it signs in, or that it is missing.
    /// VoiceOver reads its place among the others in its value, and offers its moves and removal.
    /// While Reorder is on, its Move Up and Move Down buttons follow it.
    private func row(_ jumpHost: HostEditorModel.JumpHost, at index: Int, of count: Int) -> some View {
        let detail = jumpHost.host?.connectionSummary ?? JumpHostDisplay.missingDetail
        let spokenDetail = jumpHost.host?.spokenConnectionSummary ?? JumpHostDisplay.missingDetail
        return HStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(index + 1)")
                    .font(Typography.data)
                    .foregroundStyle(Palette.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if jumpHost.host == nil {
                            // Not by colour alone: the icon and the name say it too.
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.statusError)
                        }
                        Text(jumpHost.name)
                            .font(Typography.rowTitle)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    Text(detail)
                        .font(Typography.dataCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(jumpHost.name)
            .accessibilityValue("\(index + 1) of \(count), \(spokenDetail)")
            .accessibilityIdentifier("jump-host")
            .accessibilityActions {
                if index > 0 {
                    Button("Move Up") { move(jumpHost, at: index, by: -1, of: count, refocus: true) }
                }
                if index < count - 1 {
                    Button("Move Down") { move(jumpHost, at: index, by: 1, of: count, refocus: true) }
                }
                // Otherwise VoiceOver offers the swipe action, which Reorder turns off.
                if editMode.isEditing {
                    Button("Remove") { remove(jumpHost, at: index) }
                }
            }
            .accessibilityFocused($focusedJumpHost, equals: jumpHost.id)
            if editMode.isEditing {
                moveButton(jumpHost, at: index, by: -1, of: count)
                moveButton(jumpHost, at: index, by: 1, of: count)
            }
        }
        .contextMenu {
            if index > 0 {
                Button("Move Up", systemImage: "arrow.up") {
                    move(jumpHost, at: index, by: -1, of: count, refocus: true)
                }
            }
            if index < count - 1 {
                Button("Move Down", systemImage: "arrow.down") {
                    move(jumpHost, at: index, by: 1, of: count, refocus: true)
                }
            }
            Button("Remove", systemImage: "trash", role: .destructive) { remove(jumpHost, at: index) }
        }
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash", role: .destructive) { remove(jumpHost, at: index) }
        }
    }

    /// Reorder's button that moves `jumpHost` one place up, or down. Its name says which jump host it
    /// moves, as it shows only its symbol. The first row has no Move Up and the last no Move Down,
    /// rather than dimmed ones, whose contrast would be too low to read; their places stay empty, so
    /// that the buttons line up from row to row.
    @ViewBuilder
    private func moveButton(
        _ jumpHost: HostEditorModel.JumpHost, at index: Int, by offset: Int, of count: Int
    ) -> some View {
        let isUp = offset < 0
        if isUp ? index > 0 : index < count - 1 {
            Button(
                isUp ? "Move \(jumpHost.name) Up" : "Move \(jumpHost.name) Down",
                systemImage: isUp ? "chevron.up" : "chevron.down"
            ) {
                move(jumpHost, at: index, by: offset, of: count, refocus: false)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .tint(Palette.accentInk)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        } else {
            Color.clear
                .frame(width: 44, height: 44)
        }
    }

    /// Moves `jumpHost` and says where it is now. A move from the row's actions or menu keeps
    /// VoiceOver and Switch Control on the jump host; one from its buttons leaves them on the button.
    private func move(
        _ jumpHost: HostEditorModel.JumpHost, at index: Int, by offset: Int, of count: Int, refocus: Bool
    ) {
        model.moveJumpHost(at: index, by: offset)
        announce("\(jumpHost.name), \(index + offset + 1) of \(count)")
        if refocus {
            focusedJumpHost = jumpHost.id
        }
    }

    private func remove(_ jumpHost: HostEditorModel.JumpHost, at index: Int) {
        model.removeJumpHosts(at: IndexSet(integer: index))
        announce("Removed \(jumpHost.name)")
    }

    /// What the jump hosts do, and the route they make, the first jump host's own jump hosts
    /// included.
    private var footer: String {
        guard let route = try? model.route?.get() else {
            return model.jumpHosts.isEmpty
                ? "Shello connects to this host directly. Add a jump host to reach it through another saved SSH host, "
                    + "as ProxyJump does." : Self.howItConnects
        }
        return "Route: \(JumpHostDisplay.shown(route.hops.map(\.name))). " + Self.howItConnects
    }

    private var spokenFooter: String {
        guard let route = try? model.route?.get() else { return footer }
        return "Route: \(JumpHostDisplay.spoken(route.hops.map(\.name))). " + Self.howItConnects
    }

    private static let howItConnects =
        "Shello connects to the first host from this device, and to each of the others through the one before it. "
        + "Each host checks its own host key and signs in its own way."
}

/// The saved SSH hosts to add as the next jump host, by name, with a search field when there are
/// many. Choosing one adds it and goes back.
struct JumpHostPicker: View {
    let model: HostEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// The number of hosts from which the list gets a search field.
    private static let searchableCount = 8

    var body: some View {
        Group {
            if model.jumpHostCandidates.count > Self.searchableCount {
                list.searchable(text: $search, prompt: "Search hosts")
            } else {
                list
            }
        }
        // A search that empties the list says so, after VoiceOver has read what was typed: the
        // empty state comes up while VoiceOver is in the search field.
        .onChange(of: shownCandidates.isEmpty ? search : nil) { _, emptySearch in
            if let emptySearch, !emptySearch.isEmpty {
                announce("No results for \(emptySearch)", priority: .low)
            }
        }
        // A link's destination takes the font of the list the link is in, the jump hosts' here.
        .environment(\.font, nil)
    }

    private var list: some View {
        let candidates = shownCandidates
        return List {
            Section {
                ForEach(candidates) { host in
                    Button {
                        model.addJumpHost(host.id)
                        announce("Added \(host.name)")
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.name)
                                .font(Typography.rowTitle)
                                .foregroundStyle(Palette.textPrimary)
                            Text(host.connectionSummary)
                                .font(Typography.dataCaption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .accessibilityLabel(host.name)
                    .accessibilityValue(host.spokenConnectionSummary)
                    .accessibilityIdentifier("jump-host-choice")
                }
            } footer: {
                // Not under the empty state, which says why there is nothing to choose.
                if !candidates.isEmpty {
                    FooterText("Only SSH hosts can be jump hosts. The new jump host comes last.")
                }
            }
            .listRowBackground(Palette.cell)
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .overlay {
            if model.jumpHostCandidates.isEmpty {
                EmptyStateView(
                    title: "No Hosts to Add", systemImage: "server.rack",
                    description: "A jump host is a saved SSH host. Add it as a host first, with how to sign in to it.")
            } else if candidates.isEmpty {
                EmptyStateView(
                    title: "No Results for “\(search)”", systemImage: "magnifyingglass",
                    description: "Search looks at names, addresses and users.")
            }
        }
        .navigationTitle("Add Jump Host")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The candidates that contain every word of the search, in their name, address or user.
    private var shownCandidates: [Host] {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return model.jumpHostCandidates }
        return model.jumpHostCandidates.filter { host in
            words.allSatisfy { word in
                [host.name, host.address, host.username].contains { $0.localizedStandardContains(word) }
            }
        }
    }
}
