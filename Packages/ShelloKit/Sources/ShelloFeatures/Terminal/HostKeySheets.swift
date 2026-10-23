import ShelloCore
import ShelloModel
import SwiftUI
import UIKit

/// The first connection to a server: its host key's type and fingerprint, to trust or not (README
/// section 3). Trusting covers every host that points at the server.
struct HostKeyTrustSheet: View {
    let question: TrustQuestion
    let answer: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "Shello hasn’t connected to \(question.server.description) before. Trust its host key "
                            + "only if the fingerprint matches the one the server’s administrator gives you.")
                }
                .listRowBackground(Palette.cell)

                Section {
                    HostKeyRows(key: question.key)
                } header: {
                    SectionHeader("Host Key")
                } footer: {
                    FooterText("Trust covers every host that points at \(question.server.description).")
                }
                .listRowBackground(Palette.cell)
            }
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Trust This Server?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { answer(false) }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust", systemImage: "checkmark", role: .confirm) { answer(true) }
                        .prominentToolbarButton()
                }
            }
        }
    }
}

/// A server that identified itself with another host key than the one the user trusted: Shello did
/// not connect (README section 3). Once the server's administrator confirms the new key, the user
/// can replace the trusted key with it: an explicit action, which asks for confirmation, then Face
/// ID, Touch ID or the passcode (STACK section 7.2). Shello then connects again.
struct HostKeyChangedSheet: View {
    let change: HostKeyChange
    /// Whether the user is being asked to authenticate for the replacement.
    let isReplacing: Bool
    /// Why the last replacement did not happen.
    let problem: String?
    let replace: () -> Void
    let close: () -> Void
    @State private var confirmsReplacement = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("The host key of \(change.server.description) changed.")
                            .font(Typography.rowTitle)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.statusError)
                    }
                    .labelStyle(.row)
                    Text(
                        "Someone may be intercepting the connection, or the server was reinstalled or given a new "
                            + "key. Shello didn’t connect, and sent no password.")
                }
                .listRowBackground(Palette.cell)

                Section {
                    HostKeyRows(key: change.trusted.key, name: "Trusted Key")
                    LabeledContent("Trusted") {
                        ValueText(change.trusted.trustedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    SectionHeader("Trusted Key")
                }
                .listRowBackground(Palette.cell)

                Section {
                    HostKeyRows(key: change.presented, name: "Key Presented Now")
                } header: {
                    SectionHeader("Key Presented Now")
                } footer: {
                    FooterText("Ask the server’s administrator whether its host key changed, and for its fingerprint.")
                }
                .listRowBackground(Palette.cell)

                Section {
                    Button("Replace Trusted Key…", systemImage: "key.horizontal") { confirmsReplacement = true }
                        .labelStyle(.row)
                        .destructiveStyle()
                        .disabled(isReplacing)
                    if let problem {
                        // In a list, a long problem would wrap under its icon.
                        ProblemText(problem: problem)
                            .labelStyle(.row)
                    }
                } footer: {
                    FooterText(
                        "Replace it only if the administrator confirms that the fingerprint above is the server’s. "
                            + "Shello then trusts it for every host on \(change.server.description), and asks you "
                            + "to confirm that it’s you first.")
                }
                .listRowBackground(Palette.cell)
            }
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Host Key Changed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close, action: close)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .confirmationDialog(
                "Replace the trusted host key of \(change.server.description)?", isPresented: $confirmsReplacement,
                titleVisibility: .visible
            ) {
                Button("Replace Key", role: .destructive, action: replace)
                Button("Cancel", role: .cancel) {}
            } message: {
                // The fingerprint is on the sheet, where VoiceOver spells it out; a dialog cannot.
                Text("Shello will trust the \(change.presented.typeName) key presented now in its place.")
            }
        }
    }
}

/// A host key's type and its fingerprint, which VoiceOver spells out four characters at a time, to
/// compare with what the server's administrator reads out, and which it can copy.
private struct HostKeyRows: View {
    let key: HostKey
    /// Which key VoiceOver says it is, on a sheet that shows two.
    var name: String?

    var body: some View {
        LabeledContent("Type") {
            ValueText(key.typeName, font: Typography.data)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.map { "\($0), Type" } ?? "Type")
        .accessibilityValue(key.typeName)
        VStack(alignment: .leading, spacing: 4) {
            Text("Fingerprint")
            Text(key.fingerprint)
                .font(Typography.data)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.map { "\($0), Fingerprint" } ?? "Fingerprint")
        .accessibilityValue(Text(key.spokenFingerprint))
        .accessibilityIdentifier("fingerprint")
        .accessibilityAction(named: "Copy Fingerprint") {
            UIPasteboard.general.string = key.fingerprint
            announce("Copied")
        }
    }
}

extension HostKey {
    /// The fingerprint as VoiceOver reads it: "SHA-256", then the hash spelled out four characters
    /// at a time, punctuation included, so that `/` and `+` are said too.
    var spokenFingerprint: AttributedString {
        let prefix = "SHA256:"
        var rest = fingerprint.hasPrefix(prefix) ? fingerprint.dropFirst(prefix.count) : fingerprint[...]
        var spoken = AttributedString(fingerprint.hasPrefix(prefix) ? "SHA-256, " : "")
        while !rest.isEmpty {
            var group = AttributedString(String(rest.prefix(4)))
            group.accessibilitySpeechSpellsOutCharacters = true
            group.accessibilitySpeechIncludesPunctuation = true
            spoken += group
            rest = rest.dropFirst(4)
            if !rest.isEmpty {
                spoken += AttributedString(", ")
            }
        }
        return spoken
    }
}
