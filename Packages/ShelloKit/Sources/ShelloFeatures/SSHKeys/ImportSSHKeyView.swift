import ShelloSSH
import ShelloSecurity
import SwiftUI
import UniformTypeIdentifiers

/// The import sheet (README section 13): the private key, pasted with the system's Paste button or
/// picked in the Files app, which the sheet shows as what it is, never as its text; its passphrase,
/// when it is encrypted; then the key's name and when it may sign, as for a new key.
struct ImportSSHKeyView: View {
    @State private var model: ImportSSHKeyModel
    private let onImport: (SSHKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var nameIsFocused: Bool
    @FocusState private var passphraseIsFocused: Bool
    /// Where VoiceOver goes when the private key's rows change under it: to the key once there is
    /// one, which says what it is; to the section's header once it is removed, with Paste and Choose
    /// File after it.
    @AccessibilityFocusState private var voiceOverFocus: KeyFocus?

    private enum KeyFocus: Hashable {
        case header
        case loadedKey
    }

    /// A sheet that imports a key into `store`, and hands it to `onImport` before it closes.
    init(store: SSHKeyStore, onImport: @escaping (SSHKey) -> Void = { _ in }) {
        _model = State(initialValue: ImportSSHKeyModel(store: store))
        self.onImport = onImport
    }

    var body: some View {
        NavigationStack {
            Form {
                privateKeySection
                SSHKeyNameSection(name: $model.name, problem: model.visibleNameProblem, isFocused: $nameIsFocused)
                SigningPolicySection(policy: $model.signingPolicy)
            }
            // On the form only: toolbar items keep the system font, which follows Dynamic Type.
            .font(Typography.body)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Import SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", systemImage: "checkmark", role: .confirm) { Task { await importKey() } }
                        .disabled(!model.canImport)
                        .prominentToolbarButton()
                }
            }
            .fileImporter(isPresented: $model.isPickingFile, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url):
                    model.load(fileAt: url)
                case .failure(let error):
                    SSHKeyListModel.logger.error("The file picker failed: \(error)")
                    model.fileChoiceFailed()
                }
                keyArrived()
            }
            // bcrypt makes an encrypted key take a moment on purpose.
            .onChange(of: model.isImporting) { _, isImporting in
                if isImporting { announce(importingText, priority: .low) }
            }
            .alert(
                "Couldn’t Import the SSH Key",
                isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.importError ?? "")
            }
        }
        // The sheet can open from a list that sets the design's font.
        // Toolbar items keep the system font, which follows Dynamic Type.
        .environment(\.font, nil)
    }

    // MARK: - Sections

    /// Paste and Choose File, until there is a key; then the key, with Remove, and its passphrase
    /// when it is encrypted. At accessibility text sizes Remove goes under the key, with its name,
    /// so that the key's description keeps the row's width.
    private var privateKeySection: some View {
        Section {
            if let loaded = model.loaded {
                let layout =
                    dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    LoadedKeyRow(loaded: loaded)
                        .accessibilityFocused($voiceOverFocus, equals: .loadedKey)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                    }
                    removeButton
                }
                if model.needsPassphrase {
                    passphraseField
                }
                if model.isImporting {
                    Label {
                        Text(importingText)
                    } icon: {
                        ProgressView()
                            .accessibilityHidden(true)
                    }
                    .labelStyle(.row)
                    .foregroundStyle(Palette.textSecondary)
                }
            } else {
                PasteButton(payloadType: String.self) { texts in
                    Task { @MainActor in paste(texts.first ?? "") }
                }
                .labelStyle(.titleAndIcon)
                // The system draws the button's title in white on its tint: the deep accent keeps
                // 7.3:1 in both appearances.
                .tint(Palette.accentDeep)
                Button("Choose File…", systemImage: "folder") { model.isPickingFile = true }
                    .labelStyle(.row)
            }
        } header: {
            SectionHeader("Private Key")
                .accessibilityFocused($voiceOverFocus, equals: .header)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let problem = model.loadProblem {
                    ProblemText(problem: problem)
                }
                if model.loaded == nil {
                    FooterText(
                        "A private key in OpenSSH’s format or in PEM: Ed25519, ECDSA P-256 or P-384, or RSA of 2048 "
                            + "bits or more.")
                } else {
                    FooterText(
                        "Shello keeps the key in this device’s Keychain, not its passphrase, and empties the clipboard "
                            + "once a pasted key is imported.")
                }
            }
        }
        .listRowBackground(Palette.cell)
    }

    /// Lets the key go. Only the symbol removes it, not a tap anywhere in the row; at accessibility
    /// text sizes its name shows too.
    private var removeButton: some View {
        Button(role: .destructive) {
            model.removeKey()
            focusVoiceOver(on: .header)
            announce("Removed the private key", priority: .low)
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                Label("Remove Private Key", systemImage: "xmark.circle.fill")
                    .labelStyle(.row)
            } else {
                Label("Remove Private Key", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
        }
        .buttonStyle(.borderless)
        .destructiveStyle()
        // For Voice Control, which otherwise takes only the whole name.
        .accessibilityInputLabels(["Remove Private Key", "Remove Key", "Remove"])
    }

    private var passphraseField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldRow(label: "Passphrase") {
                SecureField("Passphrase", text: $model.passphrase, prompt: Text("required"))
                    .accessibilityLabel("Passphrase")
                    .accessibilityHint(model.passphraseProblem ?? "")
                    .font(Typography.data)
                    .textContentType(.password)
                    .focused($passphraseIsFocused)
                    .submitLabel(.done)
                    .onSubmit { passphraseIsFocused = false }
            }
            if let problem = model.passphraseProblem {
                ProblemText(problem: problem)
            }
        }
    }

    // MARK: - Helpers

    private func paste(_ text: String) {
        model.paste(text)
        keyArrived()
    }

    /// After a paste or a file: VoiceOver goes to the key, which says what it is, or hears why
    /// Shello doesn't take it. The button it was on is gone either way, or about to be.
    private func keyArrived() {
        if let problem = model.loadProblem {
            announce(problem)
        } else if model.loaded != nil {
            focusVoiceOver(on: .loadedKey)
        }
    }

    /// Moves VoiceOver to `element` once the rows that replaced the ones it was on are drawn.
    private func focusVoiceOver(on element: KeyFocus) {
        Task { @MainActor in voiceOverFocus = element }
    }

    /// What the sheet does while it imports.
    private var importingText: String {
        model.needsPassphrase ? "Checking the passphrase…" : "Importing the key…"
    }

    private func importKey() async {
        nameIsFocused = false
        passphraseIsFocused = false
        if let key = await model.importKey() {
            onImport(key)
            announce("Imported the SSH key \(key.comment)")
            dismiss()
        } else if let problem = model.passphraseProblem {
            passphraseIsFocused = true
            announce(problem)
        } else if let problem = model.visibleNameProblem {
            nameIsFocused = true
            announce(problem)
        } else if let problem = model.loadProblem {
            announce(problem)
        }
    }
}

/// The private key the sheet holds, as what it is and where it came from: never its text.
private struct LoadedKeyRow: View {
    let loaded: ImportSSHKeyModel.LoadedKey

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(loaded.file.title)
                    .foregroundStyle(Palette.textPrimary)
                Text(details)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: loaded.file.isEncrypted ? "lock.fill" : "key.fill")
                .foregroundStyle(Palette.textSecondary)
        }
        .labelStyle(.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Private Key")
        .accessibilityValue("\(loaded.file.title), \(details)")
        .accessibilityHint(loaded.file.isEncrypted ? "Enter its passphrase to import it." : "")
    }

    /// Whether the key is encrypted, and where it came from.
    private var details: String {
        let encryption = loaded.file.isEncrypted ? "Encrypted" : "Not encrypted"
        switch loaded.source {
        case .clipboard: return "\(encryption), from the clipboard"
        case .file(let name): return "\(encryption), from “\(name)”"
        }
    }
}

extension SSHKeyFile {
    /// What the key is, by its format: "OpenSSH Private Key".
    var title: String {
        switch format {
        case .openSSH: "OpenSSH Private Key"
        case .pem: "PEM Private Key"
        case .pkcs8: "PKCS #8 Private Key"
        }
    }
}
