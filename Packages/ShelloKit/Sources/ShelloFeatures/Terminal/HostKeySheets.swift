import ShelloCore
import ShelloModel
import SwiftUI
import UIKit

/// The first connection to a server: its host key's type and fingerprint, to trust or not (README
/// section 3). Trusting covers every host that points at the server. On a route through jump hosts,
/// the sheet names the host whose server it is, under its title too, and where it is on the way:
/// one sheet comes up for each hop, alike but for that. VoiceOver starts on the introduction, which
/// says whose key it is, rather than on the buttons.
struct HostKeyTrustSheet: View {
    let question: TrustQuestion
    let answer: (Bool) -> Void
    @AccessibilityFocusState private var isIntroductionFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(introduction)
                        .accessibilityFocused($isIntroductionFocused)
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
            .navigationSubtitle(question.hop.place == .direct ? "" : question.hop.name)
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
            .onAppear { isIntroductionFocused = true }
        }
    }

    /// Which server it is: by its address and port, and on a route, by its host too, as the hop
    /// before reaches it.
    private var introduction: String {
        let server = question.server.description
        let advice = "Trust its host key only if the fingerprint matches the one the server’s administrator gives you."
        switch question.hop.place {
        case .direct:
            return "Shello hasn’t connected to \(server) before. \(advice)"
        case .jumpHost(let destination):
            return "Shello hasn’t connected to \(question.hop.name), at \(server), before. It’s a jump host on the way "
                + "to \(destination). \(advice)"
        case .behindJumpHost(let jumpHost):
            return "Shello hasn’t connected to \(question.hop.name) before. The jump host \(jumpHost) reaches it at "
                + "\(server). \(advice)"
        }
    }
}

/// A server that identified itself with another host key than the one the user trusted: Shello did
/// not connect (README section 3). Once the server's administrator confirms the new key, the user
/// can replace the trusted key with it: an explicit action, which asks for confirmation, then Face
/// ID, Touch ID or the passcode (STACK section 7.2). Shello then connects again. At a jump host, the
/// sheet names it: the route stopped there.
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
                        Text(headline)
                            .font(Typography.rowTitle)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.statusError)
                    }
                    .labelStyle(.row)
                    Text(explanation)
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

    /// Whose host key changed: the server's, and on a route, its host's.
    private var headline: String {
        let server = change.server.description
        switch change.hop.place {
        case .direct: return "The host key of \(server) changed."
        case .jumpHost: return "The host key of the jump host \(change.hop.name), at \(server), changed."
        case .behindJumpHost: return "The host key of \(change.hop.name), at \(server), changed."
        }
    }

    /// What may have happened, and what Shello did.
    private var explanation: String {
        let cause = "Someone may be intercepting the connection, or the server was reinstalled or given a new key."
        if case .jumpHost(let destination) = change.hop.place {
            return "\(cause) Shello stopped there, sent no password, and didn’t go on to \(destination)."
        }
        return "\(cause) Shello didn’t connect, and sent no password."
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
