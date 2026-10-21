import ShelloModel
import ShelloSecurity
import ShelloStorage
import SwiftUI

/// One host's details, with Connect, Edit, Favorite and Delete. It is the detail column in a split
/// view, and the screen a row pushes in a navigation stack.
struct HostDetailView: View {
    @State private var model: HostDetailModel
    /// Called once the host no longer exists, so that the caller can close the details.
    private let onGone: () -> Void

    @State private var editsHost: Host?
    @State private var confirmsDelete = false

    init(repository: HostRepository, secrets: SecretStore?, hostID: Host.ID, onGone: @escaping () -> Void) {
        _model = State(initialValue: HostDetailModel(repository: repository, secrets: secrets, hostID: hostID))
        self.onGone = onGone
    }

    var body: some View {
        Group {
            if let host = model.host {
                details(host)
            } else if model.isGone {
                EmptyStateView(title: "Host Deleted", systemImage: "trash", description: "This host no longer exists.")
            } else {
                ProgressView("Loading the host")
                    .labelsHidden()
            }
        }
        .background(Palette.ground)
        .navigationTitle(model.host?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let host = model.host {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit", systemImage: "pencil") { editsHost = host }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(
                        host.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: host.isFavorite ? "star.fill" : "star"
                    ) {
                        Task {
                            if await model.setFavorite(!host.isFavorite) {
                                announce(host.isFavorite ? "Removed from Favorites" : "Added to Favorites")
                            }
                        }
                    }
                }
            }
        }
        .task { await model.observe() }
        .onChange(of: model.isGone) { _, isGone in
            if isGone { onGone() }
        }
        .sheet(item: $editsHost) { host in
            HostEditorView(repository: model.repository, secrets: model.secrets, host: host)
        }
        .confirmationDialog(
            "Delete “\(model.host?.name ?? "")”?", isPresented: $confirmsDelete, titleVisibility: .visible
        ) {
            Button("Delete Host", role: .destructive) {
                // The details close once the host is gone, so the name is taken first.
                let name = model.host?.name ?? ""
                Task {
                    if await model.delete() { announce("Deleted \(name)") }
                }
            }
        } message: {
            Text("This removes the host from Shello.")
        }
        .alert(
            "Couldn’t Change the Host",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private func details(_ host: Host) -> some View {
        List {
            Section {
                Button {
                    model.connect()
                } label: {
                    Label("Connect", systemImage: "play.fill")
                        .font(Typography.rowTitle)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accentFill()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                FooterText("Connecting comes with terminal tabs.")
            }

            Section {
                valueRow("Protocol", host.protocol.displayName)
                dataRow("Address", host.address)
                dataRow("Port", String(host.port))
                dataRow("User", host.username.isEmpty ? nil : host.username)
                valueRow("Authentication", host.authMethod.displayName)
            } header: {
                SectionHeader("Connection")
            }
            .listRowBackground(Palette.cell)

            Section {
                valueRow("Group", model.groupName ?? "None")
                LabeledContent("Tags") {
                    if model.hostTags.isEmpty {
                        ValueText("None")
                    } else {
                        TagLine(tags: model.hostTags)
                    }
                }
                .accessibilityElement(children: .combine)
            } header: {
                SectionHeader("Organize")
            }
            .listRowBackground(Palette.cell)

            Section {
                dataRow("Startup command", host.startupCommand.isEmpty ? nil : host.startupCommand)
                dataRow("Terminal type", host.terminalType)
                valueRow("Keepalive", host.keepaliveInterval.formattedSeconds)
                    .accessibilityValue(host.keepaliveInterval.spokenSeconds)
                valueRow("Connect timeout", host.connectTimeout.formattedSeconds)
                    .accessibilityValue(host.connectTimeout.spokenSeconds)
            } header: {
                SectionHeader("On Connect")
            }
            .listRowBackground(Palette.cell)

            if !host.notes.isEmpty {
                Section {
                    Text(host.notes)
                } header: {
                    SectionHeader("Notes")
                }
                .listRowBackground(Palette.cell)
            }

            Section {
                Button("Delete Host", role: .destructive) { confirmsDelete = true }
                    .destructiveStyle()
            }
            .listRowBackground(Palette.cell)
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            ValueText(value)
        }
    }

    /// A value the user reads exactly, such as an address, in the data font. Nil shows "None".
    private func dataRow(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            if let value {
                ValueText(value, font: Typography.data)
                    .textSelection(.enabled)
            } else {
                ValueText("None")
            }
        }
    }
}

extension Duration {
    /// Whole seconds, such as "30 secs".
    var formattedSeconds: String {
        formatted(.units(allowed: [.seconds], width: .abbreviated))
    }

    /// Whole seconds as VoiceOver reads them, such as "30 seconds".
    var spokenSeconds: String {
        formatted(.units(allowed: [.seconds], width: .wide))
    }
}
