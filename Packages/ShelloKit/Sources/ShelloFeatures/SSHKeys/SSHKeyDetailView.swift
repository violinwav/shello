import ShelloSecurity
import SwiftUI

/// One SSH key's details (README section 13): the public key, with Copy, Share and Install on Host;
/// the fingerprint; what kind of key it is, where it came from and when it signs; and Delete. The
/// private key is not shown, nor can it be: Shello never lets it out of the device.
struct SSHKeyDetailView: View {
    @State private var model: SSHKeyDetailModel
    @Environment(\.dismiss) private var dismiss
    @Environment(TerminalTabsModel.self) private var tabs: TerminalTabsModel?
    @State private var confirmsDelete = false
    @State private var installs = false

    init(store: SSHKeyStore, key: SSHKey) {
        _model = State(initialValue: SSHKeyDetailModel(store: store, key: key))
    }

    /// What deleting `key` does, under the confirmation.
    static func deleteMessage(for key: SSHKey) -> String {
        key.kind.isImported
            ? "Servers that accept only this key won’t let you in with Shello anymore, until you import it again."
            : "Servers that accept only this key won’t let you in with Shello anymore. This can’t be undone."
    }

    private var key: SSHKey { model.key }

    var body: some View {
        List {
            publicKeySection
            fingerprintSection
            detailsSection
            Section {
                Button("Delete SSH Key", role: .destructive) { confirmsDelete = true }
                    .destructiveStyle()
            }
            .listRowBackground(Palette.cell)
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle(key.comment)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete “\(key.comment)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete SSH Key", role: .destructive) {
                if model.delete() {
                    announce("Deleted \(key.comment)")
                    dismiss()
                }
            }
        } message: {
            Text(Self.deleteMessage(for: key))
        }
        .alert(
            "Couldn’t Delete the SSH Key",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(isPresented: $installs) {
            InstallSSHKeyView(model: InstallSSHKeyModel(key: key, tabs: tabs))
        }
        // A link's destination takes the font of the list the link is in; the screen sets its own.
        .environment(\.font, nil)
    }

    private var publicKeySection: some View {
        Section {
            Text(key.openSSHPublicKey)
                .font(Typography.dataCaption)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                // VoiceOver would read the base64 for half a minute: it says what the text is, and
                // offers the text itself in the More Content rotor.
                .accessibilityLabel("\(key.algorithmName) public key, \(key.comment)")
                .accessibilityCustomContent("Public key", key.openSSHPublicKey)
            Button("Copy Public Key", systemImage: "doc.on.doc") {
                model.copyPublicKey()
                announce("Copied the public key.")
            }
            .labelStyle(.row)
            ShareLink(item: key.openSSHPublicKey, subject: Text(key.comment)) {
                Label("Share Public Key", systemImage: "square.and.arrow.up")
                    .labelStyle(.row)
            }
            Button("Install on Host…", systemImage: "server.rack") { installs = true }
                .labelStyle(.row)
        } header: {
            SectionHeader("Public Key")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if model.hasCopied {
                    Label("Copied the public key.", systemImage: "checkmark.circle")
                        .labelStyle(.row)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                FooterText(
                    "Add it to ~/.ssh/authorized_keys on each server this key signs in to, or install it on a host "
                        + "you’re connected to.")
            }
        }
        .listRowBackground(Palette.cell)
    }

    private var fingerprintSection: some View {
        Section {
            // Read one character at a time, so that VoiceOver users can compare it by ear too.
            Text(key.publicKey.fingerprint)
                .speechSpellsOutCharacters()
                .font(Typography.data)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
        } header: {
            SectionHeader("Fingerprint")
        } footer: {
            FooterText("SHA-256, as ssh-keygen -l shows it.")
        }
        .listRowBackground(Palette.cell)
    }

    private var detailsSection: some View {
        Section {
            // The name in full, which the inline title may cut short.
            LabeledContent("Name") { ValueText(key.comment, font: Typography.data) }
            valueRow("Algorithm", key.algorithmName)
            valueRow("Stored In", key.kind.storage)
            valueRow("Source", key.kind.isImported ? "Imported" : "Made on This Device")
            valueRow("Signing", key.signingPolicy.displayName)
            valueRow(
                // "Imported On", so that VoiceOver does not hear "Imported" twice, after the source.
                key.kind.isImported ? "Imported On" : "Created",
                key.createdAt.formatted(date: .abbreviated, time: .shortened))
        } header: {
            SectionHeader("Details")
        } footer: {
            if key.kind.isImported {
                FooterText(
                    "Shello keeps the private key in this device’s Keychain only: it can’t export it, and no backup or "
                        + "sync takes it along. Its passphrase isn’t kept.")
            } else {
                FooterText(
                    "The private key never leaves this device: Shello can’t export it, and no backup or sync takes it "
                        + "along.")
            }
        }
        .listRowBackground(Palette.cell)
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            ValueText(value)
        }
    }
}
