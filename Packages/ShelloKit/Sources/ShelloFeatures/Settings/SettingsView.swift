import Foundation
import ShelloStorage
import SwiftUI

/// The settings sheet: export and import of the user's data, and About with the diagnostics of the
/// SSH library.
struct SettingsView: View {
    @Environment(\.exportRepository) private var exportRepository

    var body: some View {
        SettingsList(exportRepository: exportRepository)
    }
}

/// The settings, with export and import when the environment has the export repository.
private struct SettingsList: View {
    @Environment(\.dismiss) private var dismiss
    @State private var exportImport: ExportImportModel?

    init(exportRepository: ExportRepository?) {
        _exportImport = State(initialValue: exportRepository.map { ExportImportModel(repository: $0) })
    }

    var body: some View {
        NavigationStack {
            List {
                if let exportImport {
                    ExportImportSection(model: exportImport)
                }
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
            .exportAndImport(exportImport)
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

/// Export and Import. Under them, first what is under way or what the last one did, where it stays
/// in view at large text sizes, then what an export holds.
private struct ExportImportSection: View {
    let model: ExportImportModel

    var body: some View {
        Section {
            Button("Export Data…", systemImage: "square.and.arrow.up") {
                Task { await model.export() }
            }
            .labelStyle(.row)
            Button("Import Data…", systemImage: "square.and.arrow.down") {
                model.isImporting = true
            }
            .labelStyle(.row)
        } header: {
            SectionHeader("Export and Import")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let activity = model.activity {
                    HStack(spacing: 8) {
                        // The text says what the spinner shows.
                        ProgressView()
                            .accessibilityHidden(true)
                        FooterText(activity)
                    }
                } else if let status = model.status {
                    Label(status, systemImage: "checkmark.circle")
                        .labelStyle(.row)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                FooterText(
                    "One JSON file with your hosts, groups and tags. Passwords and SSH keys are never in it. "
                        + "Importing a file adds its hosts, groups and tags, and replaces any already in Shello "
                        + "with the file’s version. Nothing else changes.")
            }
        }
        .disabled(model.isWorking)
        .listRowBackground(Palette.cell)
    }
}

/// The file exporter and importer, and the alerts of export and import.
private struct ExportImportPresentations: ViewModifier {
    @Bindable var model: ExportImportModel

    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: $model.isExporting,
                document: model.exportDocument,
                contentTypes: [.json],
                defaultFilename: model.exportFilename
            ) { result in
                model.exportFinished(result)
            } onCancellation: {
                model.exportCancelled()
            }
            .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.json]) { result in
                Task { await model.fileChosen(result) }
            }
            .alert(
                model.alert?.title ?? "",
                isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                presenting: model.alert
            ) { alert in
                if case .confirmImport(let pending) = alert {
                    Button("Import") { Task { await model.confirmImport(pending) } }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { alert in
                Text(alert.message)
            }
    }
}

extension View {
    /// Export and import's presentations, for `model`; none without one.
    @ViewBuilder
    fileprivate func exportAndImport(_ model: ExportImportModel?) -> some View {
        if let model {
            modifier(ExportImportPresentations(model: model))
        } else {
            self
        }
    }
}
