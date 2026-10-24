import ShelloCore
import ShelloSSH
import SwiftUI
import UIKit

/// The terminal's connection, from its Connection button: the key exchange it negotiated, marked
/// post-quantum or classical in words and by its symbol (README section 14). Through jump hosts
/// (README section 3), each connection along the route is listed with its own, the jump hosts' first.
/// VoiceOver reads each algorithm's name with its punctuation, and can copy it. A warning for
/// classical key exchanges, and requiring a post-quantum one, come in v1.
struct ConnectionSheet: View {
    /// The connections along the tab's route, the tab's own host's last.
    let keyExchanges: [RouteKeyExchange]
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if keyExchanges.count == 1, let keyExchange = keyExchanges[0].keyExchange {
                    Section {
                        KeyExchangeRows(keyExchange: keyExchange)
                    } footer: {
                        FooterText(Self.postQuantumExplanation)
                    }
                    .listRowBackground(Palette.cell)
                } else {
                    ForEach(Array(keyExchanges.enumerated()), id: \.offset) { index, hop in
                        let isLast = index == keyExchanges.count - 1
                        Section {
                            if let keyExchange = hop.keyExchange {
                                KeyExchangeRows(keyExchange: keyExchange, hostName: hop.hostName)
                            } else {
                                Text("Shello doesn’t know this connection’s key exchange.")
                            }
                        } header: {
                            SectionHeader(isLast ? hop.hostName : "\(hop.hostName), jump host")
                        } footer: {
                            if isLast {
                                FooterText(Self.postQuantumExplanation + " " + Self.routeExplanation)
                            }
                        }
                        .listRowBackground(Palette.cell)
                    }
                }
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

    private static let postQuantumExplanation =
        "A post-quantum key exchange protects recorded traffic from being decrypted later by a quantum computer. "
        + "Shello offers post-quantum key exchanges first, and a connection uses the first one that the server also "
        + "offers."

    private static let routeExplanation =
        "Through jump hosts, each connection has a key exchange of its own: the connection to the host runs inside "
        + "those to the jump hosts."
}

/// A key exchange's marking, post-quantum or classical in words and by its symbol, and its
/// algorithm, which VoiceOver reads with its punctuation and can copy. Along a route, the
/// algorithm's name says whose it is, as VoiceOver may reach it without its section's header.
private struct KeyExchangeRows: View {
    let keyExchange: KeyExchange
    /// The host of the connection, along a route through jump hosts; nil for a direct one.
    var hostName: String?

    var body: some View {
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
        .accessibilityLabel(hostName.map { "\($0), Algorithm" } ?? "Algorithm")
        .accessibilityValue(Text(keyExchange.spokenName))
        .accessibilityIdentifier("key-exchange")
        .accessibilityAction(named: "Copy Algorithm") {
            UIPasteboard.general.string = keyExchange.name
            announce("Copied")
        }
    }
}

/// How a tab's connection is marked on its Connection button (README section 14): post-quantum only
/// when every connection along its route is, and classical, or unknown on a jump host, otherwise, in
/// words and by its symbol.
struct ConnectionMarking: Equatable {
    let title: String
    let systemImage: String

    /// The marking of the connections along a route, the tab's own host's last; nil while Shello
    /// knows no key exchange of the tab's own host.
    init?(_ keyExchanges: [RouteKeyExchange]) {
        guard let own = keyExchanges.last?.keyExchange else { return nil }
        let jumpHosts = keyExchanges.dropLast().map(\.keyExchange)
        if !own.isPostQuantum || jumpHosts.allSatisfy({ $0?.isPostQuantum == true }) {
            (title, systemImage) = (own.title, own.systemImage)
        } else if jumpHosts.contains(where: { $0?.isPostQuantum == false }) {
            // The host's own connection is post-quantum, inside a classical one to a jump host.
            (title, systemImage) = ("Classical Key Exchange on a Jump Host", "lock")
        } else {
            // Inside a connection to a jump host whose key exchange Shello doesn't know, as the
            // sheet says: not marked post-quantum.
            (title, systemImage) = ("Unknown Key Exchange on a Jump Host", "lock")
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
