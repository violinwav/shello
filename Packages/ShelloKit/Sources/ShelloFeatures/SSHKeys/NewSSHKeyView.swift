import ShelloSecurity
import SwiftUI
import UIKit

/// The new SSH key sheet (README section 13): a name, the kind of key where the device offers a
/// choice, and when the key may sign. "Every use" comes with a warning that every reconnect asks.
struct NewSSHKeyView: View {
    @State private var model: NewSSHKeyModel
    private let onCreate: (SSHKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLock) private var appLock
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
                nameSection
                kindSection
                signingSection
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
            // The warning replaces the footer while VoiceOver is still on the choice.
            .onChange(of: model.signingPolicy) { _, policy in
                if policy == .everyUse { announce(everyUseWarning, priority: .low) }
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

    private var nameSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                // Names such as "deploy@ci" are identifiers, which autocorrection would change.
                TextField("Name", text: name, prompt: Text("required"), axis: .vertical)
                    .accessibilityLabel("Name")
                    .accessibilityHint(model.visibleNameProblem ?? "")
                    .font(Typography.data)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($nameIsFocused)
                    .submitLabel(.done)
                    .onSubmit { nameIsFocused = false }
                if let problem = model.visibleNameProblem {
                    ProblemText(problem: problem)
                }
            }
        } header: {
            SectionHeader("Name")
        } footer: {
            FooterText(
                "The name goes at the end of the public key, so that a server’s authorized_keys shows whose key it is.")
        }
        .listRowBackground(Palette.cell)
    }

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

    private var signingSection: some View {
        Section {
            Picker("Signing", selection: $model.signingPolicy) {
                ForEach(SigningPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            SectionHeader("Signing")
        } footer: {
            switch model.signingPolicy {
            case .whileUnlocked:
                FooterText("The key signs without asking again once you’ve unlocked Shello with \(biometry).")
            case .everyUse:
                // An icon and a sentence, not only a colour.
                Label(everyUseWarning, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.row)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .listRowBackground(Palette.cell)
    }

    // MARK: - Helpers

    /// The name as its field edits it. The field wraps, so that a long name stays readable at large
    /// text sizes, but the name stays on one line: Return puts the keyboard away instead of starting
    /// a new line, and a pasted line break goes.
    private var name: Binding<String> {
        Binding {
            model.name
        } set: { name in
            guard name.contains(where: \.isNewline) else {
                model.name = name
                return
            }
            model.name = name.filter { !$0.isNewline }
            nameIsFocused = false
        }
    }

    /// README section 13: the UI warns that "every use" makes every reconnect prompt.
    private var everyUseWarning: String {
        "Every connection and every reconnect with this key asks for \(biometry)."
    }

    /// What the device asks for, as app lock knows it.
    private var biometry: String {
        appLock?.biometry.inSentence ?? "Face ID or Touch ID"
    }

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
