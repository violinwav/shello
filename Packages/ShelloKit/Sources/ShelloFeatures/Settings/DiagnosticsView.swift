import ShelloSSH
import SwiftUI

/// Shows that libssh links and runs inside the app, with its version, and what Shello's algorithm
/// policy offers servers, in its order (README sections 4 and 14): the key exchanges, post-quantum
/// ones marked, the ciphers, the MACs, and the host key and SSH key algorithms. The terminal demo
/// tries the terminal without a server.
struct DiagnosticsView: View {
    private let libSSHVersion = LibSSH.version
    private let policy = AlgorithmPolicy.standard

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
                ForEach(policy.keyExchanges, id: \.self) { name in
                    AlgorithmRow(name: name, isPostQuantum: policy.postQuantumKeyExchanges.contains(name))
                }
            } header: {
                SectionHeader("Key Exchanges")
            } footer: {
                FooterText(
                    "Algorithm policy \(policy.version). Shello offers these in this order, and a connection uses the "
                        + "first one the server offers too. SHA-1, CBC ciphers and DSA are off.")
            }
            .listRowBackground(Palette.cell)

            algorithmSection("Ciphers", policy.ciphers)
            algorithmSection("MACs", policy.macs)
            algorithmSection("Host Keys", policy.hostKeyAlgorithms)
            algorithmSection("SSH Keys", policy.sshKeyAlgorithms)

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

    private func algorithmSection(_ title: String, _ names: [String]) -> some View {
        Section {
            ForEach(names, id: \.self) { name in
                AlgorithmRow(name: name)
            }
        } header: {
            SectionHeader(title)
        }
        .listRowBackground(Palette.cell)
    }
}

/// An algorithm's name, as SSH writes it, and for a key exchange whether it is post-quantum, in
/// words, never only by colour.
private struct AlgorithmRow: View {
    let name: String
    var isPostQuantum = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(Typography.data)
                .accessibilityLabel(Self.spokenName(name))
                .accessibilityValue(isPostQuantum ? "Post-quantum" : "")
            if isPostQuantum {
                // VoiceOver hears it as the name's value.
                Text("Post-quantum")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Names such as `chacha20-poly1305@openssh.com`, with the `@` read out as a word. The audit
    /// takes a label with the `@` itself for one that is not human-readable.
    private static func spokenName(_ name: String) -> String {
        name.replacing("@", with: " at ")
    }
}
