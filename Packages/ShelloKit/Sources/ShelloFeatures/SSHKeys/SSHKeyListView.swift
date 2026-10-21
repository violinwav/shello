import ShelloSecurity
import SwiftUI

/// The SSH keys on this device (README section 13), in Settings. Each row opens the key's details;
/// New SSH Key makes one.
struct SSHKeyListView: View {
    @State private var model: SSHKeyListModel
    @State private var createsKey = false
    @State private var keyToDelete: SSHKey?

    init(store: SSHKeyStore) {
        _model = State(initialValue: SSHKeyListModel(store: store))
    }

    var body: some View {
        List {
            ForEach(model.keys) { key in
                NavigationLink {
                    SSHKeyDetailView(store: model.store, key: key)
                } label: {
                    SSHKeyRow(key: key)
                }
                .accessibilityLabel(key.comment)
                .accessibilityValue(key.summary)
                .listRowBackground(Palette.cell)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { keyToDelete = key }
                }
                // For a long press, a pointer and Voice Control, which have no swipe.
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { keyToDelete = key }
                }
            }
        }
        // On the list only: toolbar items and sheets keep the system font, which follows Dynamic Type.
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .overlay { emptyState }
        .navigationTitle("SSH Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New SSH Key", systemImage: "plus") { createsKey = true }
            }
        }
        .onAppear { model.load() }
        .sheet(isPresented: $createsKey, onDismiss: { model.load() }) {
            NewSSHKeyView(store: model.store)
        }
        .confirmationDialog(
            keyToDelete.map { "Delete “\($0.comment)”?" } ?? "",
            isPresented: Binding(get: { keyToDelete != nil }, set: { if !$0 { keyToDelete = nil } }),
            titleVisibility: .visible,
            presenting: keyToDelete
        ) { key in
            Button("Delete SSH Key", role: .destructive) {
                if model.delete(key) { announce("Deleted \(key.comment)") }
            }
        } message: { _ in
            Text(SSHKeyDetailView.deleteMessage)
        }
        .alert(
            "Couldn’t Delete the SSH Key",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        // A link's destination takes the font of the list the link is in, Settings' here. Toolbar
        // items, the empty state's button and sheets keep the system font, which follows Dynamic Type.
        .environment(\.font, nil)
    }

    @ViewBuilder private var emptyState: some View {
        if let loadError = model.loadError {
            EmptyStateView(
                title: "Couldn’t Read the SSH Keys", systemImage: "exclamationmark.triangle", description: loadError)
        } else if model.hasLoaded, model.keys.isEmpty {
            // Short, like the host list's: the empty state does not scroll, and must fit at large text sizes.
            EmptyStateView(
                title: "No SSH Keys", systemImage: "key",
                description: "An SSH key signs you in to servers without a password."
            ) {
                Button("New SSH Key") { createsKey = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accentFill()
            }
        }
    }
}

/// An SSH key in the list: its name, and what kind of key it is.
struct SSHKeyRow: View {
    let key: SSHKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key.comment)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
            Text(key.summary)
                .font(Typography.footnote)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 4)
    }
}
