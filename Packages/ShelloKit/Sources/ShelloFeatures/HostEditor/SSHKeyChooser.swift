import ShelloSecurity
import SwiftUI

/// The host editor's choice of SSH key: none, one of this device's keys, or a new one made here. A
/// key the host refers to that is not on this device stays chosen until the user picks another.
/// Choosing goes back to the editor.
struct SSHKeyChooser: View {
    let model: HostEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var createsKey = false
    @State private var madeKey = false

    var body: some View {
        List {
            Section {
                choice("None", isSelected: model.draft.sshKeyID == nil) { model.chooseSSHKey(nil) }
                if model.sshKeyIsMissing {
                    // Chosen already; picking it keeps it.
                    choice("Not on this device", detail: "Made on another device, or deleted", isSelected: true) {}
                }
                ForEach(model.sshKeys) { key in
                    choice(key.comment, detail: key.summary, isSelected: model.draft.sshKeyID == key.id) {
                        model.chooseSSHKey(key.id)
                    }
                }
            } footer: {
                if model.sshKeys.isEmpty {
                    FooterText("There are no SSH keys on this device yet.")
                }
            }
            .listRowBackground(Palette.cell)

            if model.keys != nil {
                Section {
                    Button("New SSH Key…", systemImage: "plus") { createsKey = true }
                        .labelStyle(.row)
                } footer: {
                    FooterText("A new key signs in to a server once its public key is in the server’s authorized_keys.")
                }
                .listRowBackground(Palette.cell)
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("SSH Key")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.loadSSHKeys() }
        // Back in the editor once the new key is made: it is the host's key now.
        .sheet(isPresented: $createsKey, onDismiss: { if madeKey { dismiss() } }) {
            if let store = model.keys {
                NewSSHKeyView(store: store) { key in
                    model.didCreate(key)
                    madeKey = true
                }
            }
        }
        // A link's destination takes the font of the list the link is in, the editor's here.
        .environment(\.font, nil)
    }

    /// A row that chooses, with a checkmark while it is the choice. VoiceOver hears "selected" from
    /// the trait, and the detail as the value.
    private func choice(
        _ title: String, detail: String? = nil, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(Palette.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Palette.accentInk)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
