import ShelloCore
import ShelloModel
import ShelloSecurity
import ShelloStorage
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The import from an OpenSSH config file and a known_hosts file (README section 3), a sheet from
/// Settings: the files, picked in Files; then the preview of what importing them does, which the
/// user imports or cancels; then the summary of what was imported, where the lines left out stay
/// listed.
///
/// The preview can be long. Each of its parts is a section with a header, which VoiceOver's headings
/// rotor moves between, and each row is one element: a host with what it still needs first, then
/// where it signs in, its jump hosts, forwards and SSH key; a host key with its server and line, its
/// fingerprint in More Content; a line left out with its place and why, the line itself in More
/// Content. The overview at the top says what the import does before any row, and VoiceOver hears it
/// once a file is read. Keys that differ from trusted ones come before the keys to trust.
struct OpenSSHImportView: View {
    @State private var model: OpenSSHImportModel
    @Environment(\.dismiss) private var dismiss
    /// Where VoiceOver goes once the import is done: the summary's status, which replaced the preview.
    @AccessibilityFocusState private var statusIsFocused: Bool

    init(repository: HostImportRepository, sshKeys: SSHKeyStore?) {
        _model = State(initialValue: OpenSSHImportModel(repository: repository, sshKeys: sshKeys))
    }

    var body: some View {
        NavigationStack {
            List {
                if let summary = model.summary {
                    summarySections(summary)
                } else {
                    FilesSection(model: model)
                    if let plan = model.plan {
                        previewSections(plan)
                    }
                }
            }
            // The summary is a list of its own, which starts at its top, with what the import did,
            // however far the preview was scrolled.
            .id(model.summary == nil)
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle(model.summary == nil ? "Import from OpenSSH" : "Imported from OpenSSH")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .fileImporter(isPresented: $model.isPicking, allowedContentTypes: [.data]) { result in
                let kind = model.pickedKind
                Task {
                    // VoiceOver stays on the file's row, so it hears what the preview now says.
                    guard await model.fileChosen(kind, result), let file = model.file(kind) else { return }
                    announce("Read \(file.name), \(OpenSSHImportDisplay.count(file.lineCount, "line")). \(overview)")
                }
            }
            .alert(
                "Couldn’t Import",
                isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.problem ?? "")
            }
            .interactiveDismissDisabled(model.isImporting)
        }
        // Settings sets the design's font on its list; toolbar items keep the system font.
        .environment(\.font, nil)
    }

    /// What the preview says, or that there is nothing to import, for VoiceOver.
    private var overview: String {
        model.plan.map(OpenSSHImportDisplay.overview) ?? "Nothing to import."
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.summary == nil {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    // Only the import itself, one short transaction, waits.
                    .disabled(model.isImporting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import", systemImage: "checkmark", role: .confirm) {
                    Task {
                        await model.importPlan()
                        // The summary replaced the preview: VoiceOver goes to what it says first.
                        if model.summary != nil {
                            Task { @MainActor in statusIsFocused = true }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canImport)
                .prominentToolbarButton()
                .accessibilityHint(importHint)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .prominentToolbarButton()
            }
        }
    }

    /// Why Import is dimmed, or what it does: VoiceOver reads a dimmed button's hint too.
    private var importHint: String {
        guard let plan = model.plan else { return "Choose a config file or a known_hosts file first." }
        if plan.addsNothing { return "There’s nothing new to import." }
        return model.canImport ? "Adds what the preview lists." : ""
    }

    // MARK: - Preview

    @ViewBuilder
    private func previewSections(_ plan: OpenSSHImportPlan) -> some View {
        Section {
            Text(OpenSSHImportDisplay.overview(plan))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityIdentifier("import-overview")
        } header: {
            SectionHeader("Preview")
        }
        .listRowBackground(Palette.cell)
        if !plan.hosts.isEmpty {
            Section {
                ForEach(plan.hosts) { host in
                    NewHostRow(host: host)
                }
            } header: {
                SectionHeader("Hosts to Add (\(plan.hosts.count))")
            } footer: {
                FooterText(
                    "Hosts that sign in with an SSH key Shello doesn’t have yet keep the key to choose: import it "
                        + "under SSH Keys, then choose it in the host.")
            }
            .listRowBackground(Palette.cell)
        }
        // Before the keys to trust, which can be many: these are the ones to look at.
        conflictsSection(plan.conflicts)
        if !plan.keys.isEmpty {
            Section {
                ForEach(plan.keys, id: \.self) { key in
                    HostKeyRow(server: key.server, key: key.key, line: key.line)
                }
            } header: {
                SectionHeader("Host Keys to Trust (\(plan.keys.count))")
            } footer: {
                FooterText("Shello trusts one host key a server: of several, Ed25519 first, then ECDSA, then RSA.")
            }
            .listRowBackground(Palette.cell)
        }
        let alreadyTrusted = plan.knownKeys.filter { !$0.isConflict }
        if !plan.existingHosts.isEmpty || !alreadyTrusted.isEmpty {
            Section {
                ForEach(plan.existingHosts, id: \.self) { existing in
                    ExistingHostRow(existing: existing)
                }
                ForEach(alreadyTrusted, id: \.self) { known in
                    HostKeyRow(server: known.server, key: known.key, line: known.line, note: "Trusted already")
                }
            } header: {
                SectionHeader("Already in Shello (\(plan.existingHosts.count + alreadyTrusted.count))")
            } footer: {
                FooterText("They stay as they are.")
            }
            .listRowBackground(Palette.cell)
        }
        notImportedSection(plan.notImported)
    }

    /// The keys of the file that differ from the ones Shello trusts, which it keeps.
    @ViewBuilder
    private func conflictsSection(_ conflicts: [OpenSSHImportPlan.KnownKey]) -> some View {
        if !conflicts.isEmpty {
            Section {
                ForEach(conflicts, id: \.self) { conflict in
                    HostKeyRow(
                        server: conflict.server, key: conflict.key, line: conflict.line,
                        note: "Differs from the \(conflict.trusted.typeName) key Shello trusts", isProblem: true)
                }
            } header: {
                SectionHeader("Different Host Keys (\(conflicts.count))")
            } footer: {
                FooterText(OpenSSHImportDisplay.conflictDetail)
            }
            .listRowBackground(Palette.cell)
        }
    }

    /// Every line, or part of one, that the import leaves out, with why.
    @ViewBuilder
    private func notImportedSection(_ items: [OpenSSHImportPlan.NotImported]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    NotImportedRow(item: item)
                }
            } header: {
                SectionHeader("Not Imported (\(items.count))")
            } footer: {
                FooterText("Shello imports Host, HostName, User, Port, IdentityFile, ProxyJump and the forwards.")
            }
            .listRowBackground(Palette.cell)
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private func summarySections(_ summary: OpenSSHImportModel.Summary) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // Decoration: the text says it.
                Image(systemName: "checkmark.circle")
                    .accessibilityHidden(true)
                Text(summary.status)
                    .accessibilityFocused($statusIsFocused)
                    .accessibilityIdentifier("import-status")
            }
            .foregroundStyle(Palette.textPrimary)
        }
        .listRowBackground(Palette.cell)
        if !summary.keyFiles.isEmpty {
            Section {
                ForEach(summary.keyFiles, id: \.file) { keyFile in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(keyFile.file)
                            .font(Typography.data)
                            .foregroundStyle(Palette.textPrimary)
                        Text("For \(keyFile.hosts.formatted(.list(type: .and)))")
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                SectionHeader("SSH Keys to Import (\(summary.keyFiles.count))")
            } footer: {
                FooterText(
                    "Import each under Settings, SSH Keys, Import SSH Key: picked from Files, it keeps its file’s "
                        + "name. Then choose it in each host.")
            }
            .listRowBackground(Palette.cell)
        }
        if !summary.hosts.isEmpty {
            Section {
                ForEach(summary.hosts) { host in
                    NewHostRow(host: host)
                }
            } header: {
                SectionHeader("Added Hosts (\(summary.hosts.count))")
            }
            .listRowBackground(Palette.cell)
        }
        conflictsSection(summary.conflicts)
        if !summary.keys.isEmpty {
            Section {
                ForEach(summary.keys, id: \.self) { key in
                    HostKeyRow(server: key.server, key: key.key, line: key.line)
                }
            } header: {
                SectionHeader("Trusted Host Keys (\(summary.keys.count))")
            }
            .listRowBackground(Palette.cell)
        }
        notImportedSection(summary.notImported)
    }
}

/// The two files, each a row that opens Files to choose it, with what is chosen, and Remove.
private struct FilesSection: View {
    let model: OpenSSHImportModel

    var body: some View {
        Section {
            FileRow(model: model, kind: .config, systemImage: "doc.text")
            FileRow(model: model, kind: .knownHosts, systemImage: "checkmark.shield")
        } header: {
            SectionHeader("Files")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let activity = model.activity {
                    HStack(spacing: 8) {
                        // The text says what the spinner shows.
                        ProgressView()
                            .accessibilityHidden(true)
                        FooterText(activity)
                    }
                }
                FooterText(
                    "Choose your OpenSSH config file, such as ~/.ssh/config, for its hosts, and your known_hosts file, "
                        + "if you like, for the host keys you trust. Shello reads only these files: an Include is "
                        + "listed, not followed. Nothing is imported until you tap Import."
                )
                // VoiceOver reads the path's tilde and slashes.
                .accessibilityLabel(
                    "Choose your OpenSSH config file, such as the config file in your home folder’s .ssh folder, "
                        + "for its hosts, and your known_hosts file, if you like, for the host keys you trust. "
                        + "Shello reads only these files: an Include is listed, not followed. Nothing is imported "
                        + "until you tap Import.")
            }
        }
        .disabled(model.isWorking)
        .listRowBackground(Palette.cell)
    }
}

/// A file to choose: its kind and, once chosen, its name and length, or "Choose…". The row opens
/// Files; a chosen file can be removed from its menu, or VoiceOver's actions. The value goes under
/// the title, where a long file name has the row's width rather than squeezing the title.
private struct FileRow: View {
    let model: OpenSSHImportModel
    let kind: OpenSSHImportModel.FileKind
    let systemImage: String

    var body: some View {
        let file = model.file(kind)
        let value = file.map { "\($0.name), \(OpenSSHImportDisplay.count($0.lineCount, "line"))" } ?? "Choose…"
        Button {
            model.choose(kind)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(kind.title, systemImage: systemImage)
                    .labelStyle(.row)
                    .foregroundStyle(Palette.textPrimary)
                ValueText(value, font: Typography.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .accessibilityLabel(kind.title)
        .accessibilityValue(
            file.map { "\($0.name), \(OpenSSHImportDisplay.count($0.lineCount, "line"))" } ?? "None chosen"
        )
        .accessibilityHint(file == nil ? "Opens Files to choose it." : "Opens Files to choose another.")
        .accessibilityInputLabels(kind.inputLabels)
        .accessibilityIdentifier(kind == .config ? "config-file" : "known-hosts-file")
        .swipeActions {
            if file != nil {
                Button("Remove", systemImage: "xmark.circle", role: .destructive) { remove() }
            }
        }
        .contextMenu {
            if file != nil {
                Button("Remove \(kind.title)", systemImage: "xmark.circle", role: .destructive) { remove() }
            }
        }
        .accessibilityActions {
            if file != nil {
                Button("Remove \(kind.title)") { remove() }
            }
        }
    }

    /// Leaves the file out, and tells VoiceOver what the preview says now.
    private func remove() {
        Task {
            await model.remove(kind)
            let overview = model.plan.map(OpenSSHImportDisplay.overview) ?? "Nothing to import."
            announce("Removed the \(kind.title). \(overview)", priority: .low)
        }
    }
}

extension OpenSSHImportModel.FileKind {
    /// What Voice Control takes for the row: its name, then easier ones to say.
    fileprivate var inputLabels: [String] {
        switch self {
        case .config: ["Config File", "Config", "SSH Config"]
        case .knownHosts: ["known_hosts File", "Known Hosts File", "Known Hosts"]
        }
    }
}

/// A host the import adds: its name, then where it signs in, its jump hosts, forwards, SSH key and
/// line.
private struct NewHostRow: View {
    let host: OpenSSHImportPlan.NewHost

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(host.host.name)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
            ForEach(Array(OpenSSHImportDisplay.details(host).enumerated()), id: \.offset) { _, detail in
                if detail.needsAttention {
                    // What the host still needs stands out by its symbol, not only its words.
                    Label(detail.text, systemImage: "exclamationmark.triangle")
                        .labelStyle(.row)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    Text(detail.text)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(host.host.name)
        .accessibilityValue(OpenSSHImportDisplay.spokenDetails(host))
        .accessibilityIdentifier("import-host")
    }
}

/// A host of the file that Shello has already.
private struct ExistingHostRow: View {
    let existing: OpenSSHImportPlan.ExistingHost

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(existing.name)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textPrimary)
            Text(detail)
                .font(Typography.footnote)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(existing.name)
        .accessibilityValue(spokenDetail)
    }

    private var detail: String {
        "Is \(existing.saved.name), \(OpenSSHImportDisplay.signIn(existing.saved)). Line \(existing.line)"
    }

    private var spokenDetail: String {
        "Is \(existing.saved.name), \(OpenSSHImportDisplay.spokenSignIn(existing.saved)). Line \(existing.line)"
    }
}

/// A host key and its server, with its type, line and fingerprint, and a note.
private struct HostKeyRow: View {
    let server: Server
    let key: HostKey
    let line: Int
    var note: String?
    var isProblem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(server.description)
                .font(Typography.data)
                .foregroundStyle(Palette.textPrimary)
            Text(OpenSSHImportDisplay.key(key, line: line))
                .font(Typography.footnote)
                .foregroundStyle(Palette.textSecondary)
            Text(key.fingerprint)
                .font(Typography.dataCaption)
                .foregroundStyle(Palette.textSecondary)
            if let note {
                if isProblem {
                    ProblemText(problem: note)
                } else {
                    Text(note)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OpenSSHImportDisplay.spokenServer(server))
        .accessibilityValue(spokenValue)
        // Spelled out, a fingerprint takes a quarter of a minute: VoiceOver reads it on request, from
        // More Content, so that a long list of keys stays quick to go through.
        .accessibilityCustomContent(Text("Fingerprint"), Text(key.spokenFingerprint))
        .accessibilityAction(named: "Copy Fingerprint") {
            UIPasteboard.general.string = key.fingerprint
            announce("Copied")
        }
        .accessibilityIdentifier("import-host-key")
    }

    /// The note first, then the type and line.
    private var spokenValue: String {
        (note.map { "\($0). " } ?? "") + OpenSSHImportDisplay.key(key, line: line)
    }
}

/// A line, or part of one, that the import leaves out: where, why, and the line. VoiceOver hears
/// where and why; the line, which can be a long key in base64, is in More Content.
private struct NotImportedRow: View {
    let item: OpenSSHImportPlan.NotImported

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(OpenSSHImportDisplay.place(item))
                .font(Typography.footnote)
                .foregroundStyle(Palette.textSecondary)
            Text(item.reason)
                .foregroundStyle(Palette.textPrimary)
            Text(OpenSSHImportDisplay.shownText(item.text))
                .font(Typography.dataCaption)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OpenSSHImportDisplay.place(item))
        .accessibilityValue(item.reason)
        .accessibilityCustomContent(Text("Line"), Text(OpenSSHImportDisplay.shownText(item.text)))
        .accessibilityIdentifier("not-imported")
    }
}
