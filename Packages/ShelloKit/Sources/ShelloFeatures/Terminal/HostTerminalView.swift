import ShelloCore
import ShelloModel
import ShelloTerminalUI
import SwiftUI
import UIKit

/// A host's terminal, full screen: the host's Connect button opens it (README sections 4 and 5). It
/// connects as it appears, with the trust sheet for a new host key and the block sheet for a changed
/// one, and shows above the terminal what the connection is doing until it works, and how it ended.
/// While the connection is open, the Connection button shows whether its key exchange is
/// post-quantum or classical by its symbol, and opens the connection sheet, also with Command-I
/// (README section 14). Close ends the connection. One terminal at a time, until tabs come (#28).
struct HostTerminalView: View {
    let host: Host
    @Environment(\.hostConnector) private var connector
    @Environment(\.terminalSettings) private var settings
    @Environment(\.dismiss) private var dismiss
    /// Made once the screen appears: making a terminal makes its UIKit view.
    @State private var model: HostTerminalModel?
    @State private var isShowingConnection = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    terminal(model)
                } else {
                    Color(uiColor: TerminalTheme.night.background.uiColor)
                }
            }
            // A pushed screen takes the font of the list it was pushed from.
            .environment(\.font, nil)
            .navigationTitle(host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Command-W closes what is in front: the connection sheet while it is up, which
                    // nothing else can then reach, or the terminal. Esc is the program's, and a
                    // program never gets Command-W.
                    Button("Close", systemImage: "xmark", role: .close) {
                        if isShowingConnection {
                            isShowingConnection = false
                        } else {
                            close()
                        }
                    }
                    .keyboardShortcut("w")
                }
            }
        }
        .onAppear {
            guard model == nil else { return }
            let model = HostTerminalModel(
                host: host, connector: connector,
                controller: TerminalController(
                    preferences: settings?.preferences ?? TerminalPreferences(), theme: .night,
                    typeface: DesignSystem.terminalTypeface))
            self.model = model
            model.start()
        }
    }

    private func terminal(_ model: HostTerminalModel) -> some View {
        TerminalScreen(controller: model.controller)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConnectionStatusBar(status: model.status, hostName: host.name)
            }
            .onChange(of: model.controller.preferences.fontSize) { _, fontSize in
                settings?.fontSize = fontSize
            }
            .onChange(of: model.controller.streamState) {
                model.streamChanged()
            }
            .onChange(of: model.phase) { _, phase in
                switch phase {
                case .stopped:
                    close()
                case .attached:
                    // The status bar goes, and VoiceOver's focus with it if it was there: the
                    // terminal takes it.
                    UIAccessibility.post(notification: .layoutChanged, argument: model.controller.view)
                case .connecting, .failed:
                    break
                }
            }
            .sheet(item: Binding(get: { model.trustQuestion }, set: { if $0 == nil { model.answerTrust(false) } })) {
                question in
                HostKeyTrustSheet(question: question) { trusts in model.answerTrust(trusts) }
            }
            .sheet(item: Binding(get: { model.hostKeyChange }, set: { model.hostKeyChange = $0 }), onDismiss: close) {
                change in
                HostKeyChangedSheet(change: change) { model.hostKeyChange = nil }
            }
            .toolbar {
                // While the connection is open: once it ends, the status bar says so.
                if let keyExchange = model.keyExchange, model.status == .connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Connection", systemImage: keyExchange.systemImage) { isShowingConnection = true }
                            .accessibilityValue(keyExchange.title)
                            .keyboardShortcut("i")
                    }
                }
            }
            .sheet(isPresented: $isShowingConnection) {
                if let keyExchange = model.keyExchange {
                    ConnectionSheet(keyExchange: keyExchange) { isShowingConnection = false }
                }
            }
            .onChange(of: model.status) { _, status in
                // The sheet is about the open connection.
                if status != .connected {
                    isShowingConnection = false
                }
            }
    }

    private func close() {
        model?.close()
        dismiss()
    }
}

/// What the connection is doing, over the terminal, while it is not simply working: connecting, or
/// how it ended. An icon and a sentence each, never only a colour.
private struct ConnectionStatusBar: View {
    let status: HostTerminalModel.Status
    let hostName: String

    var body: some View {
        Group {
            switch status {
            case .connected:
                EmptyView()
            case .connecting:
                bar {
                    ProgressView()
                        .accessibilityHidden(true)
                    Text("Connecting to \(hostName)…")
                }
            case .ended:
                bar {
                    Image(systemName: "powerplug")
                        .accessibilityHidden(true)
                    Text("Connection closed")
                }
            case .failed(let message):
                bar {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.statusError)
                        .accessibilityHidden(true)
                    Text(message)
                }
            }
        }
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        return ViewThatFits(in: .vertical) {
            row
            // Longer than the screen at large text sizes, as some of libssh's messages are: the
            // whole message, scrolling, and the terminal keeps the rest of the screen.
            ScrollView { row }
                .containerRelativeFrame(.vertical) { length, _ in length * 0.6 }
        }
        .font(Typography.body)
        .foregroundStyle(Palette.textPrimary)
        .background(Palette.cell)
        .overlay(alignment: .bottom) {
            Palette.hairline.frame(height: 1)
        }
    }
}
