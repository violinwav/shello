import ShelloSSH
import SwiftUI

/// Shows that libssh links and runs inside the app: its version and the key exchanges it supports.
/// Connections offer those of the algorithm policy (`AlgorithmPolicy`). The terminal demo tries the
/// terminal without a server.
struct DiagnosticsView: View {
    private let libSSHVersion = LibSSH.version
    private let keyExchanges = LibSSH.keyExchanges

    var body: some View {
        List {
            Section {
                LabeledContent("libssh") {
                    ValueText(libSSHVersion, font: Typography.data)
                }
            } footer: {
                FooterText("The SSH library inside this copy of Shello, with its crypto and compression libraries.")
            }
            .listRowBackground(Palette.cell)

            Section {
                ForEach(keyExchanges, id: \.self) { name in
                    Text(name)
                        .font(Typography.data)
                        .accessibilityLabel(Self.spokenName(name))
                }
            } header: {
                SectionHeader("Key Exchanges")
            }
            .listRowBackground(Palette.cell)

            Section {
                NavigationLink {
                    TerminalDemoView()
                } label: {
                    Label("Terminal Demo", systemImage: "apple.terminal")
                        .labelStyle(.row)
                }
            } header: {
                SectionHeader("Terminal")
            } footer: {
                FooterText(
                    "A terminal attached to a stand-in for a server on this device: try colors, Unicode, the bell "
                        + "and 10 MB of output without connecting.")
            }
            .listRowBackground(Palette.cell)
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Diagnostics")
    }

    /// Names such as `curve25519-sha256@libssh.org`, with the `@` read out as a word.
    private static func spokenName(_ name: String) -> String {
        name.replacing("@", with: " at ")
    }
}
