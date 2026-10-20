import ShelloSSH
import SwiftUI

/// Shows that libssh links and runs inside the app: its version and the key exchanges it offers.
struct DiagnosticsView: View {
    private let libSSHVersion = LibSSH.version
    private let keyExchanges = LibSSH.keyExchanges

    var body: some View {
        List {
            Section {
                LabeledContent("libssh") {
                    Text(libSSHVersion)
                        .font(Typography.data)
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
