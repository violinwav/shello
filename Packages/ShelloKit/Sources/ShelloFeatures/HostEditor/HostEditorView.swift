import ShelloModel
import ShelloSecurity
import ShelloStorage
import SwiftUI

/// The new and edit host sheet, with every MVP host field (README section 3). The password goes
/// into the Keychain; the SSH key is chosen among this device's keys.
struct HostEditorView: View {
    /// The text fields, in the order the keyboard's Next key moves through them.
    private enum FocusField: Hashable {
        case name
        case address
        case port
        case username
        case password
        case startupCommand
        case tmuxSessionName
        case terminalType
        case notes

        init(_ field: HostDraft.Field) {
            switch field {
            case .name: self = .name
            case .address: self = .address
            case .port: self = .port
            case .tmuxSessionName: self = .tmuxSessionName
            case .terminalType: self = .terminalType
            }
        }

        /// The field the draft checks, if the draft checks this one.
        var checked: HostDraft.Field? {
            switch self {
            case .name: .name
            case .address: .address
            case .port: .port
            case .tmuxSessionName: .tmuxSessionName
            case .terminalType: .terminalType
            case .username, .password, .startupCommand, .notes: nil
            }
        }
    }

    @State private var model: HostEditorModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: FocusField?

    @State private var isSaving = false
    @State private var confirmsDiscard = false
    @State private var confirmsDelete = false
    @State private var namesNewGroup = false
    @State private var newGroupName = ""

    /// An editor for `host` as the caller last read it, or for a new host.
    init(repository: HostRepository, secrets: SecretStore?, keys: SSHKeyStore?, host: Host?) {
        _model = State(
            initialValue: HostEditorModel(repository: repository, secrets: secrets, keys: keys, host: host))
    }

    var body: some View {
        NavigationStack {
            Form {
                protocolSection
                connectionSection
                authenticationSection
                organizeSection
                tagsSection
                onConnectSection
                notesSection
                if model.isEditing {
                    Section {
                        Button("Delete Host", role: .destructive) { confirmsDelete = true }
                            .destructiveStyle()
                    }
                    .listRowBackground(Palette.cell)
                }
            }
            // On the form only: toolbar items keep the system font, which follows Dynamic Type.
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            // The sheet cannot be swiped away while it has changes, so VoiceOver's escape gesture
            // goes through Cancel instead.
            .accessibilityAction(.escape) { cancel() }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) { Task { await save() } }
                        .keyboardShortcut("s")
                        .disabled(isSaving)
                        .prominentToolbarButton()
                }
                // The number pad has no Return key.
                ToolbarItemGroup(placement: .keyboard) {
                    if focus == .port {
                        Spacer()
                        Button("Next") { focus = .username }
                    }
                }
            }
            .task { await model.observeGroupsAndTags() }
            .onChange(of: focus) { left, _ in
                guard let field = left?.checked else { return }
                let wasShowing = model.visibleProblem(for: field) != nil
                model.didLeave(field)
                // A problem that appears as the user moves on is spoken after the next field.
                if !wasShowing, let problem = model.visibleProblem(for: field) {
                    announce(problem, priority: .low)
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete “\(model.storedName)”?", isPresented: $confirmsDelete, titleVisibility: .visible
            ) {
                Button("Delete Host", role: .destructive) {
                    Task {
                        if await model.delete() {
                            announce("Deleted \(model.storedName)")
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This removes the host from Shello.")
            }
            .alert("New Group", isPresented: $namesNewGroup) {
                TextField("Name", text: $newGroupName)
                    .autocorrectionDisabled()
                Button("Add") { _ = model.addGroup(named: newGroupName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The host goes into the new group.")
            }
            .alert(
                "Couldn’t Save the Host",
                isPresented: Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.saveError ?? "")
            }
        }
        // A swipe down must not throw away what the user typed; Cancel asks first.
        .interactiveDismissDisabled(model.hasChanges)
    }

    // MARK: - Sections

    private var protocolSection: some View {
        Section {
            // A segmented control keeps its text size; at large sizes it shows each segment in the
            // Large Content Viewer.
            Picker("Protocol", selection: $model.draft.protocol) {
                ForEach(HostProtocol.allCases, id: \.self) { hostProtocol in
                    Text(hostProtocol.displayName).tag(hostProtocol)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            FooterText(model.draft.protocol.summary)
        }
    }

    private var connectionSection: some View {
        Section {
            textField("Name", text: $model.draft.name, prompt: "required", focus: .name, next: .address)
            textField(
                "Address", text: $model.draft.address, prompt: "required", focus: .address, next: .port,
                keyboard: .URL)
            textField(
                "Port", text: $model.draft.port, prompt: "1–65535", focus: .port, next: .username, keyboard: .numberPad)
            textField("User", text: $model.draft.username, prompt: "optional", focus: .username)
        } header: {
            SectionHeader("Connection")
        }
        .listRowBackground(Palette.cell)
    }

    private var authenticationSection: some View {
        Section {
            Picker("Method", selection: $model.draft.authMethod) {
                ForEach(AuthMethod.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }
            if model.draft.authMethod == .sshKey {
                if model.offersSSHKeyChoice {
                    NavigationLink {
                        SSHKeyChooser(model: model)
                    } label: {
                        LabeledContent("SSH Key") { ValueText(model.sshKeySummary) }
                    }
                } else {
                    LabeledContent("SSH Key") { ValueText(model.sshKeySummary) }
                }
            }
            if model.offersPassword {
                FieldRow(label: "Password") {
                    SecureField("Password", text: $model.password, prompt: Text(model.passwordPrompt))
                        .accessibilityLabel("Password")
                        .accessibilityHint(model.passwordHint)
                        .font(Typography.data)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
                }
            }
            if model.managesStoredPassword {
                storedPasswordButton
            }
        } header: {
            SectionHeader("Authentication")
        } footer: {
            if let footer = authenticationFooter {
                FooterText(footer)
            }
        }
        .listRowBackground(Palette.cell)
        // A saved password that the new method does not use goes when the host is saved; the footer
        // says so, but VoiceOver is back on the picker.
        .onChange(of: model.draft.authMethod) {
            if let note = model.passwordNote { announce(note, priority: .low) }
        }
    }

    /// Removes the saved password when the host is saved, or keeps it after all. One button whose
    /// title changes, so that VoiceOver stays on it. Not a destructive button: Cancel undoes the
    /// removal too, and the error token marks it.
    private var storedPasswordButton: some View {
        let removes = model.removesStoredPassword
        return Button(
            removes ? "Keep Saved Password" : "Remove Saved Password",
            systemImage: removes ? "arrow.uturn.backward" : "trash"
        ) {
            if removes {
                model.keepStoredPassword()
                announce("The saved password stays.")
            } else {
                model.removeStoredPassword()
                announce("Saving removes the saved password.")
            }
        }
        .labelStyle(.row)
        .foregroundStyle(removes ? Palette.accentInk : Palette.statusError)
    }

    /// What the chosen method needs, and what saving does to a stored password.
    private var authenticationFooter: String? {
        let method: String? =
            switch model.draft.authMethod {
            case .sshKey where model.sshKeyIsMissing:
                "This host’s SSH key isn’t on this device. Choose one of this device’s keys, or make a new one."
            case .sshKey where model.chosenSSHKey != nil:
                "Copy its public key in Settings, under SSH Keys, and add it to the server’s authorized_keys."
            case .sshKey where model.offersSSHKeyChoice: "Choose an SSH key, or make a new one."
            case .sshKey: nil
            case .password where model.offersPassword:
                "Shello keeps the password in the Keychain, on this device only, and never puts it in an export."
            case .password: nil
            case .keyboardInteractive:
                "When it connects, Shello asks you the server’s questions, such as your password or a one-time code."
            }
        let parts = [method, model.passwordNote].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var organizeSection: some View {
        Section {
            Toggle("Favorite", isOn: $model.draft.isFavorite)
            Picker("Group", selection: $model.draft.groupID) {
                Text("None").tag(HostGroup.ID?.none)
                ForEach(model.groups) { group in
                    Text(group.name).tag(HostGroup.ID?.some(group.id))
                }
            }
            Button("New Group…", systemImage: "folder.badge.plus") {
                newGroupName = ""
                namesNewGroup = true
            }
        } header: {
            SectionHeader("Organize")
        }
        .listRowBackground(Palette.cell)
    }

    private var tagsSection: some View {
        Section {
            ForEach(model.tags) { tag in
                let isSelected = model.isSelected(tag)
                Button {
                    model.toggleTag(tag)
                } label: {
                    HStack {
                        ColorLabel(color: tag.color, name: tag.name)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        if isSelected {
                            // VoiceOver hears "selected" from the trait below.
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Palette.accentInk)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            NavigationLink {
                NewTagView(suggestedColor: model.suggestedTagColor) { name, color in
                    if let tag = model.addTag(named: name, color: color) {
                        announce("Added the tag \(tag.name)")
                    }
                }
            } label: {
                Label("New Tag…", systemImage: "tag")
                    .foregroundStyle(Palette.accentInk)
            }
        } header: {
            SectionHeader("Tags")
        } footer: {
            if model.tags.isEmpty {
                FooterText("Tags label hosts across groups, and filter the host list.")
            }
        }
        .listRowBackground(Palette.cell)
    }

    private var onConnectSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                // The field carries this label for VoiceOver.
                Text("Startup command")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
                TextField("Startup command", text: $model.draft.startupCommand, prompt: Text("none"), axis: .vertical)
                    .accessibilityLabel("Startup command")
                    .font(Typography.data)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .startupCommand)
            }
            // After the startup command, which runs first (README section 8).
            Toggle("Attach tmux session", isOn: $model.draft.tmuxAutoAttach)
                // Speech recognition seldom writes "tmux".
                .accessibilityInputLabels(["Attach tmux session", "Attach session"])
            if model.draft.tmuxAutoAttach {
                textField(
                    "tmux session", text: $model.draft.tmuxSessionName, prompt: "required", focus: .tmuxSessionName,
                    next: .terminalType, inputLabels: ["Session name"])
            }
            textField(
                "Terminal type", text: $model.draft.terminalType, prompt: "required", focus: .terminalType)
            StepperRow(
                "Keepalive", value: $model.draft.keepaliveSeconds, in: 5...300, step: 5,
                shown: model.draft.keepaliveInterval.formattedSeconds,
                spoken: model.draft.keepaliveInterval.spokenSeconds)
            StepperRow(
                "Connect timeout", value: $model.draft.connectTimeoutSeconds, in: 5...120, step: 5,
                shown: model.draft.connectTimeout.formattedSeconds, spoken: model.draft.connectTimeout.spokenSeconds)
        } header: {
            SectionHeader("On Connect")
        } footer: {
            FooterText(onConnectFooter)
        }
        .listRowBackground(Palette.cell)
    }

    /// What happens on connect, in the order it happens.
    private var onConnectFooter: String {
        guard model.draft.tmuxAutoAttach else {
            return "Shello runs the startup command once it has signed in, checks the connection every keepalive "
                + "interval, and stops connecting after the timeout."
        }
        return "Shello runs the startup command once it has signed in, then attaches the tmux session, or starts "
            + "it, so that the work in it carries on while Shello is away. It checks the connection every "
            + "keepalive interval, and stops connecting after the timeout."
    }

    private var notesSection: some View {
        Section {
            TextField("Notes", text: $model.draft.notes, prompt: Text("none"), axis: .vertical)
                .accessibilityLabel("Notes")
                .lineLimit(3...)
                .focused($focus, equals: .notes)
        } header: {
            SectionHeader("Notes")
        }
        .listRowBackground(Palette.cell)
    }

    // MARK: - Helpers

    /// A labelled text field for a value the user types exactly, with its problem underneath. The
    /// problem is also the field's hint, so VoiceOver reads it on the field. Return moves to `next`,
    /// or puts the keyboard away. Voice Control also takes any of `inputLabels` as the field's name.
    private func textField(
        _ label: String, text: Binding<String>, prompt: String, focus field: FocusField, next: FocusField? = nil,
        keyboard: UIKeyboardType = .default, inputLabels: [String] = []
    ) -> some View {
        let problem = field.checked.flatMap { model.visibleProblem(for: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            FieldRow(label: label) {
                TextField(label, text: text, prompt: Text(prompt))
                    .accessibilityLabel(label)
                    .accessibilityInputLabels([label] + inputLabels)
                    .accessibilityHint(problem ?? "")
                    .font(Typography.data)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: field)
                    .submitLabel(next == nil ? .done : .next)
                    .onSubmit { focus = next }
            }
            if let problem {
                ProblemText(problem: problem)
            }
        }
    }

    private func cancel() {
        if model.hasChanges { confirmsDiscard = true } else { dismiss() }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if await model.save() {
            dismiss()
        } else if let field = model.firstProblemField, let problem = model.visibleProblem(for: field) {
            focus = FocusField(field)
            // High priority: VoiceOver would otherwise cut it off to read the field that takes the focus.
            let count = model.visibleProblems.count
            announce(count > 1 ? "\(count) problems. \(problem)" : problem)
        }
    }
}

/// A stepper with its label and value: side by side while the label fits on one line beside the
/// stepper's buttons, or else the label and value over the buttons. Beside them at large text sizes,
/// "Keepalive" broke in the middle of the word and "Connect timeout" was cut off. Either way the
/// stepper is the element assistive technologies get, with its label, its spoken value and its own
/// decrement and increment buttons, which Voice Control and Switch Control reach. The texts are
/// hidden from them, as a text field's label is in `FieldRow`: a stepper's label view would put the
/// value it shows, such as "30 secs", into its name, which would then change with every step.
private struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// The value as the row shows it, such as "30 secs".
    let shown: String
    /// The value as VoiceOver reads it, such as "30 seconds".
    let spoken: String

    init(
        _ title: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int, shown: String, spoken: String
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.shown = shown
        self.spoken = spoken
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                titleText
                Spacer()
                valueText
                stepper
            }
            VStack(alignment: .leading, spacing: 4) {
                titleText
                valueText
                stepper
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .accessibilityHidden(true)
    }

    private var valueText: some View {
        ValueText(shown)
            .accessibilityHidden(true)
    }

    private var stepper: some View {
        Stepper(title, value: $value, in: range, step: step)
            .labelsHidden()
            .accessibilityValue(spoken)
    }
}
