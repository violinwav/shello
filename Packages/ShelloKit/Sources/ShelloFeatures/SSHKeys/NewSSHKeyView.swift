import ShelloSecurity
import SwiftUI
import UIKit

/// The new SSH key sheet (README section 13): a name, the kind of key where the device offers a
/// choice, and when the key may sign. "Every use" comes with a warning that every reconnect asks.
struct NewSSHKeyView: View {
    @State private var model: NewSSHKeyModel
    private let onCreate: (SSHKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool

    /// A sheet that makes a key in `store`, and hands it to `onCreate` before it closes.
    init(store: SSHKeyStore, onCreate: @escaping (SSHKey) -> Void = { _ in }) {
        _model = State(initialValue: NewSSHKeyModel(store: store, suggestedName: Self.suggestedName))
        self.onCreate = onCreate
    }

    /// The name a new key starts with, which says which device the key belongs to: on a server, it
    /// tells the user which key to remove when they lose the device (ADR 0003).
    private static var suggestedName: String {
        "Shello on \(UIDevice.current.model)"
    }

    var body: some View {
        NavigationStack {
            Form {
                SSHKeyNameSection(name: $model.name, problem: model.visibleNameProblem, isFocused: $nameIsFocused)
                kindSection
                SigningPolicySection(policy: $model.signingPolicy)
            }
            // On the form only: toolbar items keep the system font, which follows Dynamic Type.
            .font(Typography.body)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("New SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "checkmark", role: .confirm) { Task { await create() } }
                        .disabled(model.isCreating)
                        .prominentToolbarButton()
                }
            }
            .alert(
                "Couldn’t Make the SSH Key",
                isPresented: Binding(get: { model.createError != nil }, set: { if !$0 { model.createError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.createError ?? "")
            }
        }
        // The sheet can open from a list that sets the design's font, such as the host editor's.
        // Toolbar items keep the system font, which follows Dynamic Type.
        .environment(\.font, nil)
    }

    // MARK: - Sections

    @ViewBuilder private var kindSection: some View {
        if model.offersKinds {
            Section {
                Picker("Type", selection: $model.kind) {
                    ForEach(model.kinds, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                SectionHeader("Type")
            } footer: {
                FooterText(model.kind.explanation)
            }
            .listRowBackground(Palette.cell)
        } else {
            Section {
                // The header already says "Type".
                Text(SSHKey.Kind.ed25519.displayName)
            } header: {
                SectionHeader("Type")
            } footer: {
                FooterText(
                    "This device can’t make Secure Enclave keys, so the key is Ed25519. The private key stays in this "
                        + "device’s Keychain.")
            }
            .listRowBackground(Palette.cell)
        }
    }

    // MARK: - Helpers

    private func create() async {
        nameIsFocused = false
        if let key = await model.create() {
            onCreate(key)
            announce("Created the SSH key \(key.comment)")
            dismiss()
        } else if let problem = model.visibleNameProblem {
            nameIsFocused = true
            announce(problem)
        }
    }
}
