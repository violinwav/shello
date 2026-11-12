import ShelloModel
import SwiftUI

/// The host editor's screen for one port forward (README section 4): local, to a destination as the
/// server reaches it; remote, from a port the server listens on to a destination as this device
/// reaches it; or dynamic, a SOCKS5 proxy. It has the port it listens on, on 127.0.0.1 or on the
/// server, a remote forward's bind address on the server, whether it is on, and an optional name. A
/// new forward is added with Add, as a new tag is; an existing one is edited in place, and Delete
/// removes it. Like the rest of the host, nothing is stored until the host is saved, and Cancel in
/// the editor undoes it all.
struct PortForwardView: View {
    /// The text fields, in the order the keyboard's Next key moves through them.
    private enum FocusField: Hashable {
        case port
        case bindAddress
        case destinationAddress
        case destinationPort
        case name

        init(_ field: PortForwardDraft.Field) {
            switch field {
            case .port: self = .port
            case .bindAddress: self = .bindAddress
            case .destinationAddress: self = .destinationAddress
            case .destinationPort: self = .destinationPort
            }
        }
    }

    let model: HostEditorModel
    /// The forward the screen edits, or nil for a new one.
    let forwardID: PortForwardDraft.ID?

    @State private var newForward = PortForwardDraft.new
    @State private var attemptedAdd = false
    @State private var leftFields: Set<PortForwardDraft.Field> = []
    @FocusState private var focus: FocusField?
    /// Where VoiceOver is among the fields: it goes to the one whose problem keeps the forward from
    /// being added, also when that field has the keyboard already.
    @AccessibilityFocusState private var accessibilityFocus: FocusField?
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { forwardID == nil }

    /// The forward as the screen shows it: the new one, or the draft's.
    private var draft: Binding<PortForwardDraft> {
        guard let forwardID else { return $newForward }
        return Binding(
            get: { model.portForward(forwardID) ?? newForward },
            set: { model.updatePortForward($0) })
    }

    var body: some View {
        let forward = draft.wrappedValue
        Form {
            Section {
                // A segmented control keeps its text size; at large sizes it shows each segment in the
                // Large Content Viewer. Each title is one short word, which three equal segments fit
                // on the narrowest iPhone and in iPad's Slide Over; the footer says what each does.
                Picker("Kind", selection: draft.kind) {
                    Text("Local").tag(PortForwardDraft.Kind.local)
                    Text("Remote").tag(PortForwardDraft.Kind.remote)
                    Text("Dynamic").tag(PortForwardDraft.Kind.dynamic)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                FooterText(Self.summary(of: forward.kind))
                    // At its default punctuation level, VoiceOver skips the option's hyphen.
                    .accessibilityLabel(Self.summary(of: forward.kind).replacing(" -", with: " dash "))
            }

            Section {
                // One field for every kind, whose label alone changes: a field that a kind replaced
                // would take the keyboard away, and count as left, showing its problem at once.
                textField(
                    forward.kind == .remote ? "Server port" : "Local port", text: draft.port, prompt: "1–65535",
                    focus: .port, next: nextField(after: .port), keyboard: .numberPad)
                if forward.kind == .remote {
                    textField(
                        "Bind address", text: draft.bindAddress, prompt: "optional", focus: .bindAddress,
                        next: .destinationAddress, keyboard: .URL,
                        hint: "Optional. Leave it empty for the server’s loopback, or enter * for all of its addresses."
                    )
                }
                // Named for what it turns on: a switch named "On" would be read as "On, off".
                Toggle("Enabled", isOn: draft.isEnabled)
                    .accessibilityHint("A forward that is off stays saved, and doesn’t listen.")
            } header: {
                SectionHeader(forward.kind == .remote ? "Listen on the Server" : "Listen")
            } footer: {
                FooterText(listenFooter(forward))
            }
            .listRowBackground(Palette.cell)

            if forward.kind != .dynamic {
                Section {
                    // Named with their section for VoiceOver, which may reach them without its header.
                    textField(
                        "Address", spoken: "Destination address", text: draft.destinationAddress,
                        prompt: "e.g. localhost", focus: .destinationAddress, next: .destinationPort, keyboard: .URL)
                    textField(
                        "Port", spoken: "Destination port", text: draft.destinationPort, prompt: "1–65535",
                        focus: .destinationPort, next: .name, keyboard: .numberPad)
                } header: {
                    SectionHeader("Destination")
                } footer: {
                    FooterText(Self.destinationFooter(of: forward.kind))
                }
                .listRowBackground(Palette.cell)
            }

            // Without a header, which would only repeat the field's label.
            Section {
                FieldRow(label: "Name") {
                    TextField("Name", text: draft.name, prompt: Text("optional"))
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("forward-name")
                        .focused($focus, equals: .name)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
                }
            }
            .listRowBackground(Palette.cell)

            if !isNew {
                Section {
                    // With its symbol beside it, as the editor's other row buttons: as a bare title,
                    // the accessibility audit reported its text as not following Dynamic Type.
                    Button("Delete Port Forward", systemImage: "trash", role: .destructive, action: delete)
                        .labelStyle(.row)
                        .destructiveStyle()
                }
                .listRowBackground(Palette.cell)
            }
        }
        .font(Typography.body)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle(isNew ? "New Port Forward" : "Port Forward")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark", role: .confirm, action: add)
                        .prominentToolbarButton()
                        // For Voice Control: the toolbar shows only the symbol.
                        .accessibilityInputLabels(["Add", "Add Port Forward"])
                }
            }
            // The number pad has no Return key.
            ToolbarItemGroup(placement: .keyboard) {
                if focus == .port || focus == .destinationPort {
                    Spacer()
                    Button("Next") { focus = nextField(after: focus) }
                }
            }
        }
        .onChange(of: focus) { left, _ in
            // A deleted forward's screen is going: it has nothing more to say.
            guard let field = left.flatMap(Self.checkedField), !isDeleted else { return }
            let wasShowing = visibleProblem(for: field) != nil
            leftFields.insert(field)
            // A problem that appears as the user moves on is spoken after the next field.
            if !wasShowing, let problem = visibleProblem(for: field) {
                announce(problem, priority: .low)
            }
        }
        // A port that another forward that is on listens on shows at once, also when the switch or
        // the kind changed it rather than the port, and VoiceOver hears it wherever it is.
        .onChange(of: model.sharesPort(forward)) { _, shares in
            if shares, let problem = visibleProblem(for: .port) {
                announce(problem, priority: .low)
            }
        }
        .onAppear {
            if isNew { focus = .port }
        }
        // A link's destination takes the font of the list the link is in, the editor's here.
        .environment(\.font, nil)
    }

    // MARK: - Problems

    /// The problem to show for `field`: once the user has left the field, or has tried to add the
    /// forward. A port that another forward of the host listens on, on the same side, shows at once.
    private func visibleProblem(for field: PortForwardDraft.Field) -> String? {
        let forward = draft.wrappedValue
        if field == .port, model.sharesPort(forward) {
            return forward.kind == .remote
                ? "Another remote forward of this host that is on has the server listen on this port. Change the port, "
                    + "or turn one of them off."
                : "Another port forward of this host that is on listens on this port. Change the port, or turn one of "
                    + "them off."
        }
        guard attemptedAdd || leftFields.contains(field) else { return nil }
        return forward.problems[field]
    }

    /// Whether the forward this screen edited was deleted, as the screen goes.
    private var isDeleted: Bool {
        guard let forwardID else { return false }
        return model.portForward(forwardID) == nil
    }

    private static func checkedField(_ field: FocusField) -> PortForwardDraft.Field? {
        switch field {
        case .port: .port
        case .bindAddress: .bindAddress
        case .destinationAddress: .destinationAddress
        case .destinationPort: .destinationPort
        case .name: nil
        }
    }

    private func nextField(after field: FocusField?) -> FocusField? {
        switch field {
        case .port:
            switch draft.wrappedValue.kind {
            case .local: .destinationAddress
            case .remote: .bindAddress
            case .dynamic: .name
            }
        case .destinationPort: .name
        default: nil
        }
    }

    // MARK: - Actions

    /// Adds the new forward, or shows what keeps it from being added, and moves there.
    private func add() {
        attemptedAdd = true
        let problems = PortForwardDraft.Field.allCases.compactMap { field in
            visibleProblem(for: field).map { (field, $0) }
        }
        guard let (field, problem) = problems.first else {
            model.addPortForward(newForward)
            if let forward = newForward.forward {
                announce(
                    "Added the \(PortForwardDisplay.spokenKind(forward)) \(PortForwardDisplay.spokenTitle(forward))")
            }
            dismiss()
            return
        }
        focus = FocusField(field)
        accessibilityFocus = FocusField(field)
        // High priority: VoiceOver would otherwise cut it off to read the field that takes the focus.
        announce(problems.count > 1 ? "\(problems.count) problems. \(problem)" : problem)
    }

    /// Deletes the forward and goes back, where VoiceOver goes on to the next forward
    /// (`HostEditorModel.removePortForward(_:)`).
    private func delete() {
        guard let forwardID else { return }
        focus = nil
        let title = draft.wrappedValue.forward.map {
            "\(PortForwardDisplay.spokenKind($0)) \(PortForwardDisplay.spokenTitle($0))"
        }
        model.removePortForward(forwardID)
        announce(title.map { "Deleted the \($0)" } ?? "Deleted the port forward")
        dismiss()
    }

    // MARK: - Texts

    private static func summary(of kind: PortForwardDraft.Kind) -> String {
        switch kind {
        case .local:
            "Each connection to the port goes on to the destination, as the server reaches it, as ssh -L does."
        case .remote:
            "The server listens on its port, and each connection to it comes back to the destination, as this "
                + "device reaches it, as ssh -R does."
        case .dynamic:
            "A SOCKS5 proxy: each app that connects says where to go, and the server connects there and resolves "
                + "names, as ssh -D does."
        }
    }

    private func listenFooter(_ forward: PortForwardDraft) -> String {
        guard forward.kind == .remote else {
            let port = forward.listeningPort.map { "127.0.0.1, port \($0)" } ?? "127.0.0.1 on this port"
            return "Apps on this device connect to \(port), while Shello is open and the host’s tab is connected."
        }
        let port = forward.listeningPort.map { "its port \($0)" } ?? "this port"
        return "The server listens on \(port) while the host’s tab is connected, on its loopback unless you enter "
            + "another address, or * for all of them. The server’s GatewayPorts setting decides who can reach it: "
            + "by default, only the server itself."
    }

    private static func destinationFooter(of kind: PortForwardDraft.Kind) -> String {
        guard kind == .remote else {
            return "As the server reaches it: localhost is the server itself, and the server resolves a name, so a "
                + "name only its network knows works."
        }
        return "As this device reaches it: localhost is this device itself. One on your local network needs "
            + "Local Network access, which iOS asks you for once."
    }

    // MARK: - Helpers

    /// A labelled text field for a value the user types exactly, with its problem underneath, which
    /// is also the field's hint, or else `hint`. Return moves to `next`. VoiceOver and Voice Control
    /// know it as `spoken`, which contains the label, or else as its label; Voice Control by its label
    /// too.
    private func textField(
        _ label: String, spoken: String? = nil, text: Binding<String>, prompt: String, focus field: FocusField,
        next: FocusField?, keyboard: UIKeyboardType, hint: String = ""
    ) -> some View {
        let problem = Self.checkedField(field).flatMap(visibleProblem)
        let name = spoken ?? label
        return VStack(alignment: .leading, spacing: 6) {
            FieldRow(label: label) {
                TextField(name, text: text, prompt: Text(prompt))
                    .accessibilityLabel(name)
                    .accessibilityInputLabels(spoken == nil ? [label] : [name, label])
                    .accessibilityHint(problem ?? hint)
                    .font(Typography.data)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: field)
                    .accessibilityFocused($accessibilityFocus, equals: field)
                    .submitLabel(next == nil ? .done : .next)
                    .onSubmit { focus = next }
            }
            if let problem {
                // Beside its icon: one that wraps under the icon is reported as clipped text.
                ProblemText(problem: problem)
                    .labelStyle(.row)
            }
        }
    }
}
