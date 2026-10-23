import ShelloCore
import ShelloModel
import ShelloSecurity
import SwiftUI

/// Install on Host (README section 13), from a key's details: a tap on a host with an open
/// connection adds the key's public key to its `~/.ssh/authorized_keys`, as `ssh-copy-id` does, and
/// the sheet says what happened, in words and by a symbol. Without an open connection, it says how
/// to get one.
struct InstallSSHKeyView: View {
    @State private var model: InstallSSHKeyModel
    @Environment(\.dismiss) private var dismiss

    init(model: InstallSSHKeyModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            List {
                let hosts = model.hosts
                if !hosts.isEmpty {
                    Section {
                        ForEach(hosts) { target in
                            HostButton(target: target, outcome: model.outcomes[target.id]) {
                                Task { await install(on: target) }
                            }
                            .disabled(model.isInstalling)
                        }
                    } header: {
                        SectionHeader("Open Connections")
                    } footer: {
                        FooterText(
                            "Shello adds the public key to ~/.ssh/authorized_keys for the user the connection signed in "
                                + "as, as ssh-copy-id does, and makes the file if there is none. A key that’s there "
                                + "already isn’t added again.")
                    }
                    .listRowBackground(Palette.cell)
                    if let result = model.lastResult {
                        Section {
                            Text(result)
                                .foregroundStyle(Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        } header: {
                            SectionHeader("Result")
                        }
                        .listRowBackground(Palette.cell)
                    }
                }
            }
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .overlay {
                if model.hosts.isEmpty {
                    // Short: the empty state does not scroll, and must fit at large text sizes.
                    EmptyStateView(
                        title: "No Open Connections", systemImage: "network",
                        description: "Shello installs the key over an open connection. Connect to the host first.")
                }
            }
            .navigationTitle("Install on Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .environment(\.font, nil)
    }

    private func install(on target: InstallSSHKeyModel.Target) async {
        // VoiceOver does not read the button's new value by itself.
        announce("Installing on \(target.host.name)…", priority: .low)
        await model.install(on: target)
        if let result = model.lastResult {
            announce(result)
        }
    }
}

/// A host to install the key on: its name, the user and the address, and what installing did there,
/// in words and by a symbol, never by colour alone.
private struct HostButton: View {
    let target: InstallSSHKeyModel.Target
    let outcome: InstallSSHKeyModel.Outcome?
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility text sizes the symbol goes under the text, which then has the full width,
        // as in the host list: a user and an address are one long word. The text takes the height
        // it needs, so that the line breaks inside that word cut nothing off.
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        Button(action: action) {
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.host.name)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text(target.host.connectionSummary)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textSecondary)
                    if let status {
                        Text(status)
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                }
                symbol
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        // VoiceOver reads the name, then the user and the address as words, and what installing did.
        // A button with the drawn texts as its label would also show each text to the accessibility
        // audit, which takes a user and an address that nearly fill the row for text cut off.
        .accessibilityRepresentation {
            Button(target.host.name, action: action)
                .accessibilityValue(value)
                .accessibilityHint(hint)
                // For the UI tests: the host list behind the sheet has a button of the same name.
                .accessibilityIdentifier("install-host")
        }
    }

    /// The user and the address as words, then what installing did.
    private var value: String {
        [target.host.spokenConnectionSummary, status].compactMap(\.self).joined(separator: ", ")
    }

    /// What a tap does now: install, or install again, which adds no second copy of the key.
    private var hint: String {
        switch outcome {
        case nil: "Installs the key on this host."
        case .installing: ""
        case .installed: "Checks again that the host has the key."
        case .failed: "Tries installing the key again."
        }
    }

    @ViewBuilder private var symbol: some View {
        switch outcome {
        case .installing:
            ProgressView()
                .accessibilityHidden(true)
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.accentInk)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.statusError)
                .accessibilityHidden(true)
        case nil:
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(Palette.accentInk)
                .accessibilityHidden(true)
        }
    }

    /// What installing did on the host, in a word or two.
    private var status: String? {
        switch outcome {
        case .installing: "Installing…"
        case .installed(.added): "Installed"
        case .installed(.alreadyInstalled): "Installed already"
        case .failed: "Couldn’t install"
        case nil: nil
        }
    }
}
