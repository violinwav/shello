import ShelloCore
import ShelloModel
import ShelloTerminalUI
import SwiftUI
import UIKit

/// The terminal screen (README sections 4 and 5, docs/ui/ui_v1 Terminal): the selected tab's
/// terminal, under the tab bar. The title is the tab's host, with its protocol, user and latency
/// under it, the keepalive's round trip. Hosts goes back to the host list, and the tabs stay.
///
/// Above the terminal, a bar says what the connection does until it works, and how it ended or why
/// it reconnects, with Reconnect and Close Tab. The selected tab asks to trust a new host key, blocks
/// a changed one, from which the user can replace the trusted key, and asks the server's
/// keyboard-interactive questions, in sheets. While the connection works, the Connection button shows
/// whether its key exchange is post-quantum or classical, and opens the connection sheet, also with
/// Command-I (README section 14).
struct TerminalTabsView: View {
    @Bindable var model: TerminalTabsModel

    var body: some View {
        NavigationStack {
            Group {
                if let tab = model.selectedTab {
                    TabContent(tab: tab, model: model)
                        // Each tab has its own terminal, search and sheets.
                        .id(tab.id)
                } else {
                    Color(uiColor: TerminalTheme.night.background.uiColor)
                }
            }
            // A pushed screen takes the font of the list it was pushed from.
            .environment(\.font, nil)
            .navigationTitle(model.selectedTab?.host.name ?? "")
            .navigationSubtitle(model.selectedTab.map(Self.subtitle) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hosts", systemImage: "chevron.backward") { model.hideTerminals() }
                }
            }
            .safeAreaBar(edge: .top, spacing: 0) {
                TabBar(model: model)
            }
        }
        .onChange(of: model.tabs.tabs.isEmpty) { model.tabsChanged() }
        .onChange(of: SelectedState(model.selectedTab)) { old, new in
            guard old.id == new.id, let tab = model.selectedTab, let oldState = old.state, let newState = new.state
            else { return }
            model.stateChanged(of: tab, from: oldState, to: newState)
        }
    }

    /// The protocol, the user and the latency, as the UI design puts them under the title: "ssh ·
    /// deploy · 24 ms". The latency shows while the tab is active.
    static func subtitle(of tab: TerminalTab<TerminalController>) -> String {
        var parts = ["ssh", tab.host.username]
        if tab.state == .active, let latency = tab.latency {
            parts.append(latency.latencyText)
        }
        return parts.joined(separator: " · ")
    }

    /// The selected tab and its state, to tell a change of state from a change of tab.
    private struct SelectedState: Equatable {
        let id: UUID?
        let state: TabState?

        init(_ tab: TerminalTab<TerminalController>?) {
            id = tab?.id
            state = tab?.state
        }
    }
}

/// One tab's terminal, with the bar over it, its sheets and its Connection button.
private struct TabContent: View {
    let tab: TerminalTab<TerminalController>
    @Bindable var model: TerminalTabsModel
    @Environment(\.terminalSettings) private var settings
    @AccessibilityFocusState private var statusFocus: StatusBarFocus?

    var body: some View {
        TerminalScreen(controller: tab.terminal)
            .safeAreaInset(edge: .top, spacing: 0) {
                TabStatusBar(tab: tab, focus: $statusFocus) {
                    model.close(tab)
                }
            }
            .onAppear {
                guard model.passesKeyboardFocus else { return }
                // A hardware keyboard types on in the tab it switched to.
                Task { _ = tab.terminal.view.becomeFirstResponder() }
            }
            .onChange(of: tab.terminal.preferences.fontSize) { _, fontSize in
                settings?.fontSize = fontSize
            }
            .onChange(of: tab.state) { old, state in
                let wasInStatusBar = statusFocus != nil
                if state == .active {
                    // The status bar goes. VoiceOver's focus goes to the terminal if it was in the
                    // bar, or as a tab the user just opened first connects; otherwise it stays where
                    // the user put it, as when a restored tab connects once selected in the tab bar.
                    if wasInStatusBar || (tab.connectionCount == 1 && tab.id == model.tabOpenedByTheUser) {
                        UIAccessibility.post(notification: .layoutChanged, argument: tab.terminal.view)
                    }
                } else {
                    // The sheet is about the open connection.
                    model.isShowingConnection = false
                    // The bar says something else now, and the button pressed may have gone: VoiceOver's
                    // focus goes to what it says.
                    if wasInStatusBar, old.kind != state.kind {
                        statusFocus = .message
                    }
                }
            }
            // One sheet asks to trust a new host key, then the server's questions: one presentation
            // follows the other without one sheet coming up while the last one is still going.
            .sheet(item: Binding(get: { tab.prompt }, set: { if $0 == nil { tab.dismissPrompt() } })) { prompt in
                switch prompt {
                case .trust(let question):
                    HostKeyTrustSheet(question: question) { trusts in tab.answerTrust(trusts) }
                case .signIn:
                    // Named for the hop that signs in, a jump host's or the tab's own (README section 3).
                    SignInSheet(
                        question: tab.signInQuestion,
                        hostName: tab.signInQuestion?.hop.name ?? tab.currentJumpHost?.name ?? tab.host.name,
                        isThroughJumpHosts: tab.route.map { !$0.jumpHosts.isEmpty } ?? false,
                        answer: { answers in tab.answerSignIn(answers) }, cancel: { tab.dismissPrompt() })
                }
            }
            .sheet(item: Binding(get: { tab.hostKeyChange }, set: { if $0 == nil { tab.hostKeyChangeDismissed() } })) {
                change in
                HostKeyChangedSheet(
                    change: change, isReplacing: tab.isReplacingHostKey, problem: tab.replacementProblem,
                    replace: {
                        Task {
                            await tab.replaceTrustedHostKey()
                            if tab.hostKeyChange == nil {
                                announce("Replaced the trusted host key")
                            } else if let problem = tab.replacementProblem {
                                announce(problem)
                            }
                        }
                    }, close: { tab.hostKeyChangeDismissed() })
            }
            .toolbar {
                // While the connection works: otherwise the status bar says what it does. Marked for
                // the whole route, through jump hosts too.
                if let marking = ConnectionMarking(tab.keyExchanges), tab.state == .active {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Connection", systemImage: marking.systemImage) {
                            model.isShowingConnection = true
                        }
                        .accessibilityValue(marking.title)
                        .keyboardShortcut("i")
                    }
                }
            }
            .sheet(isPresented: $model.isShowingConnection) {
                if !tab.keyExchanges.isEmpty {
                    ConnectionSheet(keyExchanges: tab.keyExchanges) { model.isShowingConnection = false }
                }
            }
    }
}

/// What the selected tab's connection does, over the terminal, while it is not simply working:
/// connecting, reconnecting, or how it ended, with what the user can do about it. An icon and a
/// sentence each, never only a colour. Its buttons have touch targets of 44 points, and go one
/// under the other at the accessibility text sizes.
private struct TabStatusBar: View {
    let tab: TerminalTab<TerminalController>
    let focus: AccessibilityFocusState<StatusBarFocus?>.Binding
    let closeTab: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch tab.state {
        case .active, .closed:
            EmptyView()
        case .connecting(let step):
            bar {
                ProgressView()
                    .accessibilityHidden(true)
                // The hop the connection is at: a jump host on the way, named as one, as the sheets
                // name it, or the tab's own host.
                Text(Self.connecting(step, to: tab.currentJumpHost.map { "the jump host \($0.name)" } ?? tab.host.name))
            }
        case .reconnecting(let reconnecting):
            switch reconnecting.phase {
            case .trying, .waiting:
                bar {
                    reconnectingMessage(reconnecting)
                } actions: {
                    // There while it tries too, unavailable, so that it stays put from one try to the
                    // next.
                    action("Reconnect Now") { tab.reconnect() }
                        .disabled(!reconnecting.isWaiting)
                }
            case .waitingForNetwork, .waitingForUnlock:
                bar {
                    reconnectingMessage(reconnecting)
                }
            }
        case .suspended:
            bar {
                Image(systemName: "pause.circle")
                    .accessibilityHidden(true)
                Text("Shello closed the connection in the background. It reconnects once Shello is unlocked.")
            } actions: {
                action("Reconnect") { tab.reconnect() }
            }
        case .restored:
            bar {
                Image(systemName: "arrow.counterclockwise")
                    .accessibilityHidden(true)
                Text("Shello restored this tab. It connects once Shello is unlocked.")
            } actions: {
                action("Connect") { tab.reconnect() }
            }
        case .ended:
            bar {
                Image(systemName: "powerplug")
                    .accessibilityHidden(true)
                Text("Connection closed")
            } actions: {
                action("Reconnect") { tab.reconnect() }
                action("Close Tab", perform: closeTab)
            }
        case .disconnected(let message):
            bar {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.statusError)
                    .accessibilityHidden(true)
                Text(message)
            } actions: {
                action("Reconnect") { tab.reconnect() }
                action("Close Tab", perform: closeTab)
            }
        }
    }

    @ViewBuilder
    private func reconnectingMessage(_ reconnecting: Reconnecting) -> some View {
        ProgressView()
            .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.reconnecting(reconnecting, to: tab.hostAlongRoute))
            if !reconnecting.reason.isEmpty {
                Text(reconnecting.reason)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func action(_ title: String, perform action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .accessibilityFocused(focus, equals: .action)
    }

    static func connecting(_ step: ConnectStep, to host: String) -> String {
        switch step {
        case .connecting: "Connecting to \(host)…"
        case .verifyingHostKey: "Checking the host key of \(host)…"
        case .signingIn: "Signing in to \(host)…"
        case .startingSession: "Starting the shell on \(host)…"
        }
    }

    static func reconnecting(_ reconnecting: Reconnecting, to host: String) -> String {
        switch reconnecting.phase {
        case .trying: "Reconnecting to \(host)…"
        case .waiting(let delay):
            "Reconnecting to \(host) in \(delay.formatted(.units(allowed: [.seconds], width: .wide)))…"
        case .waitingForNetwork: "Waiting for the network to reconnect to \(host)…"
        case .waitingForUnlock: "Reconnecting to \(host) once Shello is unlocked…"
        }
    }

    /// The bar with a message only.
    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        container {
            message(content)
                .padding(.vertical, 10)
        }
    }

    /// The bar with a message and its buttons, whose touch targets make the space under it.
    private func bar(
        @ViewBuilder _ content: () -> some View, @ViewBuilder actions: () -> some View
    ) -> some View {
        let layout =
            dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 16))
        return container {
            VStack(alignment: .leading, spacing: 0) {
                message(content)
                    .padding(.top, 10)
                layout {
                    actions()
                }
                .buttonStyle(MinimumTargetButtonStyle())
                .tint(Palette.accentInk)
            }
        }
    }

    private func message(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            content()
        }
        .foregroundStyle(Palette.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityFocused(focus, equals: .message)
    }

    private func container(@ViewBuilder _ content: () -> some View) -> some View {
        let row = content()
            .padding(.horizontal, 16)
        return ViewThatFits(in: .vertical) {
            row
            // Longer than the screen at large text sizes, as some of libssh's messages are: the
            // whole message, scrolling, and the terminal keeps the rest of the screen.
            ScrollView { row }
                .containerRelativeFrame(.vertical) { length, _ in length * 0.6 }
        }
        .font(Typography.body)
        .background(Palette.cell)
        .overlay(alignment: .bottom) {
            Palette.hairline.frame(height: 1)
        }
    }
}

/// Where VoiceOver's focus is in the status bar: on its message, or on one of its buttons.
private enum StatusBarFocus: Hashable {
    case message
    case action
}

extension Reconnecting {
    /// Whether the tab waits before its next try.
    fileprivate var isWaiting: Bool {
        if case .waiting = phase { true } else { false }
    }
}

extension TabState {
    /// The state without what it carries, to tell a new state from the same one moving on.
    fileprivate var kind: Kind {
        switch self {
        case .connecting: .connecting
        case .active: .active
        case .reconnecting: .reconnecting
        case .suspended: .suspended
        case .restored: .restored
        case .ended: .ended
        case .disconnected: .disconnected
        case .closed: .closed
        }
    }

    fileprivate enum Kind {
        case connecting, active, reconnecting, suspended, restored, ended, disconnected, closed
    }
}

extension Duration {
    /// A latency as the tab shows it, in whole milliseconds: "24 ms".
    var latencyText: String {
        "\(max(1, Int((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15).rounded()))) ms"
    }

    /// A latency as VoiceOver reads it: "24 milliseconds".
    var spokenLatency: String {
        let milliseconds = max(
            1, Int((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15).rounded()))
        return Measurement(value: Double(milliseconds), unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .wide))
    }
}
