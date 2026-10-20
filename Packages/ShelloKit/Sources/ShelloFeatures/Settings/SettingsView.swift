import Foundation
import SwiftUI

/// The settings sheet. For now it holds only About, with the diagnostics of the SSH library.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Version") { ValueText(Self.version) }
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                } header: {
                    SectionHeader("About")
                }
                .listRowBackground(Palette.cell)
            }
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
    }

    /// The app's version and build, such as "0.1 (1)".
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
