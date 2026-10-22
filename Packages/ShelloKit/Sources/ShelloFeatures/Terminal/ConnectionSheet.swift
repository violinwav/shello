import ShelloSSH
import SwiftUI
import UIKit

/// The terminal's connection, from its Connection button: the key exchange it negotiated, marked
/// post-quantum or classical in words and by its symbol (README section 14). VoiceOver reads the
/// algorithm's name with its punctuation, and can copy it. A warning for classical key exchanges,
/// and requiring a post-quantum one, come in v1.
struct ConnectionSheet: View {
    let keyExchange: KeyExchange
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(keyExchange.title)
                            .font(Typography.rowTitle)
                    } icon: {
                        Image(systemName: keyExchange.systemImage)
                            .foregroundStyle(keyExchange.isPostQuantum ? Palette.accentInk : Palette.textSecondary)
                    }
                    .labelStyle(.row)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Algorithm")
                        Text(keyExchange.name)
                            .font(Typography.data)
                            .foregroundStyle(Palette.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Algorithm")
                    .accessibilityValue(Text(keyExchange.spokenName))
                    .accessibilityIdentifier("key-exchange")
                    .accessibilityAction(named: "Copy Algorithm") {
                        UIPasteboard.general.string = keyExchange.name
                        announce("Copied")
                    }
                } footer: {
                    FooterText(
                        "A post-quantum key exchange protects recorded traffic from being decrypted later by a "
                            + "quantum computer. Shello offers post-quantum key exchanges first, and a connection uses "
                            + "the first one that the server also offers.")
                }
                .listRowBackground(Palette.cell)
            }
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close, action: close)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

extension KeyExchange {
    /// Whether the key exchange is post-quantum or classical, as words.
    var title: String {
        isPostQuantum ? "Post-Quantum Key Exchange" : "Classical Key Exchange"
    }

    /// The symbol beside `title` and on the terminal's Connection button: a shield on the lock for a
    /// post-quantum key exchange, a plain lock for a classical one.
    var systemImage: String {
        isPostQuantum ? "lock.shield" : "lock"
    }

    /// The name as VoiceOver reads it: as it is written, for braille too, with its punctuation said,
    /// such as the hyphen and the `@` of `sntrup761x25519-sha512@openssh.com`.
    var spokenName: AttributedString {
        var spoken = AttributedString(name)
        spoken.accessibilitySpeechIncludesPunctuation = true
        return spoken
    }
}
