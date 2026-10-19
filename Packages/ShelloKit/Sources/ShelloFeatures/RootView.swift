import ShelloSSH
import SwiftUI

/// The app's first screen. The host list (README section 3) replaces it.
/// Until then it shows that libssh links and runs inside the app.
public struct RootView: View {
    private let libSSHVersion = LibSSH.version
    private let keyExchanges = LibSSH.keyExchanges

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("libssh", value: libSSHVersion)
                    Text("Development build. Nothing to connect to yet.")
                }
                Section("Key exchanges") {
                    ForEach(keyExchanges, id: \.self) { name in
                        Text(name)
                            .font(.body.monospaced())
                            .accessibilityLabel(Self.spokenName(name))
                    }
                }
                .headerProminence(.increased)
            }
            .navigationTitle("Shello")
        }
    }

    /// Names such as `curve25519-sha256@libssh.org`, with the `@` read out as a word.
    private static func spokenName(_ name: String) -> String {
        name.replacing("@", with: " at ")
    }
}

#Preview {
    RootView()
}
