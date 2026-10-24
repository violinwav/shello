import Foundation
import ShelloSecurity
import ShelloStorage
import ShelloTerminalUI
import SwiftUI

/// The settings sheet: export and import of the user's data, app lock, the SSH keys, the terminal,
/// the Shello keyboard and hardware keyboards, and About with the diagnostics of the SSH library and
/// the terminal demo.
struct SettingsView: View {
    @Environment(\.exportRepository) private var exportRepository
    @Environment(\.appLock) private var appLock
    @Environment(\.sshKeyStore) private var sshKeys

    var body: some View {
        SettingsList(exportRepository: exportRepository, appLock: appLock, sshKeys: sshKeys)
    }
}

/// The settings, with export and import when the environment has the export repository, app lock
/// when it has app lock, the SSH keys when it has their store, and the terminal when it has its
/// settings.
private struct SettingsList: View {
    let appLock: AppLock?
    let sshKeys: SSHKeyStore?
    @Environment(\.terminalSettings) private var terminalSettings
    @Environment(\.dismiss) private var dismiss
    @State private var exportImport: ExportImportModel?

    init(exportRepository: ExportRepository?, appLock: AppLock?, sshKeys: SSHKeyStore?) {
        self.appLock = appLock
        self.sshKeys = sshKeys
        _exportImport = State(initialValue: exportRepository.map { ExportImportModel(repository: $0) })
    }

    var body: some View {
        NavigationStack {
            List {
                if let exportImport {
                    ExportImportSection(model: exportImport)
                }
                if let appLock {
                    AppLockSection(appLock: appLock)
                }
                if let sshKeys {
                    Section {
                        NavigationLink {
                            SSHKeyListView(store: sshKeys)
                        } label: {
                            Label("SSH Keys", systemImage: "key")
                                .labelStyle(.row)
                        }
                    } footer: {
                        FooterText("SSH keys that Shello makes never leave this device. Imported keys stay on it too.")
                    }
                    .listRowBackground(Palette.cell)
                }
                if let terminalSettings {
                    TerminalSection(settings: terminalSettings)
                    ShelloKeyboardSection(settings: terminalSettings)
                    HardwareKeyboardSection(settings: terminalSettings)
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

/// How long Shello may stay in the background before app lock asks again (README section 13).
private struct AppLockSection: View {
    @Bindable var appLock: AppLock

    var body: some View {
        Section {
            Picker("Require Unlock", selection: $appLock.timeout) {
                ForEach(AppLockTimeout.allCases) { timeout in
                    Text(timeout.displayName).tag(timeout)
                }
            }
            // It would change nothing; the footer says why.
            .disabled(!appLock.canAsk)
        } header: {
            SectionHeader("App Lock")
        } footer: {
            FooterText(footer)
        }
        .listRowBackground(Palette.cell)
    }

    private var footer: String {
        guard appLock.canAsk else {
            return "This device has no passcode, so app lock can’t ask for one. Set a passcode in the Settings app "
                + "to turn app lock on."
        }
        return "Shello asks for \(appLock.biometry.inSentence) when it opens, and when you return after it has "
            + "been in the background this long. Until then, your hosts stay hidden."
    }
}

/// The terminal's text size, the scrollback's length and whether VoiceOver reads new output
/// (README sections 5 and 16). The text size is here for those who cannot pinch.
private struct TerminalSection: View {
    @Bindable var settings: TerminalSettings

    var body: some View {
        Section {
            Stepper(value: $settings.fontSize, in: TerminalPreferences.fontSizes, step: 1) {
                LabeledContent("Text Size") { ValueText("\(Int(settings.fontSize)) pt") }
            }
            .accessibilityLabel("Text Size")
            .accessibilityValue("\(Int(settings.fontSize)) points")
            Picker("Scrollback", selection: $settings.scrollbackLines) {
                ForEach(TerminalPreferences.scrollbackChoices, id: \.self) { lines in
                    Text("\(lines.formatted()) Lines").tag(lines)
                }
            }
            Toggle("Read New Output Aloud", isOn: $settings.announcesOutput)
        } header: {
            SectionHeader("Terminal")
        } footer: {
            FooterText(
                "Pinching a terminal changes its text size too. Scrollback is what a terminal keeps to scroll "
                    + "back to and search. With VoiceOver, new output is read aloud.")
        }
        .listRowBackground(Palette.cell)
    }
}

/// The Shello keyboard (README section 6): a row to its settings, which have a screen of their own.
/// Laid out in Settings itself, they made the list longer, and the accessibility audit's Dynamic
/// Type check, which makes the text larger and measures it again, then reported rows that the
/// larger text pushed below the screen, such as Require Unlock, as not growing at all.
private struct ShelloKeyboardSection: View {
    let settings: TerminalSettings

    var body: some View {
        Section {
            NavigationLink {
                ShelloKeyboardSettingsView(settings: settings)
            } label: {
                Label("Shello Keyboard", systemImage: "keyboard")
                    .labelStyle(.row)
            }
        } footer: {
            FooterText("The letters layout, haptic feedback and the swipe key.")
        }
        .listRowBackground(Palette.cell)
    }
}

/// The Shello keyboard's letters layout, its haptics and the swipe key's speed.
private struct ShelloKeyboardSettingsView: View {
    @Bindable var settings: TerminalSettings
    /// What Automatic means on this device, read once as the screen shows.
    @State private var automatic = LettersLayout.ID.automatic

    var body: some View {
        List {
            Section {
                Picker("Letters", selection: $settings.keyboardLetters) {
                    Text("Automatic (\(automatic.layout.name))").tag(LettersLayout.ID?.none)
                    ForEach(LettersLayout.ID.allCases) { letters in
                        Text(letters.layout.name).tag(Optional(letters))
                    }
                }
                Toggle("Haptic Feedback", isOn: $settings.keyboardHaptics)
                Stepper(value: $settings.swipeKeySpeed, in: KeyboardPreferences.swipeSpeeds, step: 0.25) {
                    LabeledContent("Swipe Key Speed") { ValueText("\(speed)×") }
                }
                .accessibilityLabel("Swipe Key Speed")
                // As a percentage, which VoiceOver reads well at any speed: "125 percent".
                .accessibilityValue(settings.swipeKeySpeed.formatted(.percent))
            } footer: {
                FooterText(
                    "Automatic follows the first keyboard in the Settings app. Pull a key down to type the symbol "
                        + "in its corner, or hold a letter for its accents. Tap Shift, Control or Alt twice, or hold "
                        + "it, to lock it. The swipe key sends the arrow you tap, except with VoiceOver, and arrows "
                        + "faster the further you drag; the function keys have arrows too. With VoiceOver, the "
                        + "arrows, symbols, accents and Lock are also in the Actions rotor.")
            }
            .listRowBackground(Palette.cell)
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Shello Keyboard")
    }

    /// The speed as a number, such as 1.25.
    private var speed: String {
        settings.swipeKeySpeed.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// Option as Meta and a key that sends Esc, for hardware keyboards (README section 5).
private struct HardwareKeyboardSection: View {
    @Bindable var settings: TerminalSettings

    var body: some View {
        Section {
            Toggle("Option Key as Meta", isOn: $settings.optionAsMeta)
            Picker("Extra Esc Key", selection: $settings.escapeKey) {
                ForEach(EscapeKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }
        } header: {
            SectionHeader("Hardware Keyboard")
        } footer: {
            FooterText(Self.footer(controlBracket: "Control-["))
                // VoiceOver can leave the bracket out.
                .accessibilityLabel(Self.footer(controlBracket: "Control-left bracket"))
        }
        .listRowBackground(Palette.cell)
    }

    private static func footer(controlBracket: String) -> String {
        "As Meta, Option and a key send Esc and the key, as Emacs expects. The extra Esc key is for keyboards "
            + "without one; \(controlBracket) always sends Esc. The Settings app can make Caps Lock an Esc key."
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
