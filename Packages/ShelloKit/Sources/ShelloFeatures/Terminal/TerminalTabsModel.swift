import Observation
import ShelloCore
import ShelloModel
import ShelloStorage
import ShelloTerminalUI
import SwiftUI
import UIKit
import os

/// A window's tabs on screen (README section 4): the terminal screen with its tab bar, over the host
/// list, and what it follows of the app.
/// - Connect on a host opens a tab and shows the terminal screen; Hosts goes back to the host list,
///   whose Live section leads to the tabs again. Closing the last tab goes back too.
/// - In the background, the connections stay for the short time iOS grants (a background task),
///   then close cleanly. Back in the foreground and unlocked, the tab on screen reconnects.
/// - VoiceOver hears what the selected tab's connection does.
@MainActor
@Observable
final class TerminalTabsModel {
    let tabs: TerminalTabs<TerminalController>

    /// Whether the terminal screen shows, over the host list.
    var isShowingTerminals = false {
        didSet { tabs.isOnScreen = isShowingTerminals }
    }

    /// Whether the selected tab's connection sheet shows.
    var isShowingConnection = false

    @ObservationIgnored private let settings: TerminalSettings?
    /// How long the connections stay in the background: nil for what iOS grants.
    @ObservationIgnored private let backgroundTime: Duration?
    @ObservationIgnored private var isSceneActive = false
    @ObservationIgnored private var isLocked = false
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var closingInBackground: Task<Void, Never>?
    /// Whether the terminal that was selected last had the keyboard, which the next one takes.
    @ObservationIgnored private(set) var passesKeyboardFocus = false

    /// Tabs that connect with `connector` and record their connections in `hosts`, with terminals
    /// made with `settings`. `backgroundTime` replaces the background time iOS grants, for the UI
    /// tests.
    init(connector: HostConnector, hosts: HostRepository?, settings: TerminalSettings?, backgroundTime: Duration? = nil)
    {
        self.settings = settings
        self.backgroundTime = backgroundTime
        let preferences = { settings?.preferences ?? TerminalPreferences() }
        tabs = TerminalTabs(services: TabServices(connector: connector, hosts: hosts)) { _ in
            TerminalController(preferences: preferences(), theme: .night, typeface: DesignSystem.terminalTypeface)
        }
    }

    var selectedTab: TerminalTab<TerminalController>? { tabs.selectedTab }

    // MARK: - Tabs

    /// Opens a tab for `host` and shows it (README section 4).
    func connect(to host: Host) {
        noteKeyboardFocus()
        isShowingConnection = false
        announceSlowConnection(of: tabs.open(host))
        isShowingTerminals = true
    }

    /// Shows the terminal screen on `tab`.
    func show(_ tab: TerminalTab<TerminalController>) {
        tabs.select(tab)
        isShowingTerminals = true
    }

    /// Back to the host list. The tabs stay, and their connections.
    func hideTerminals() {
        isShowingConnection = false
        isShowingTerminals = false
    }

    /// Opens another tab for the selected tab's host, as Command-T does.
    func newTab() {
        guard let host = selectedTab?.host else { return }
        connect(to: host)
    }

    func select(_ tab: TerminalTab<TerminalController>) {
        guard tab.id != tabs.selectedTabID else { return }
        noteKeyboardFocus()
        isShowingConnection = false
        tabs.select(tab)
    }

    /// Selects the next tab, as Command-Shift-] does, and tells VoiceOver which tab shows now.
    func selectNext() {
        noteKeyboardFocus()
        isShowingConnection = false
        tabs.selectNext()
        announceSelectedTab()
    }

    /// Selects the previous tab, as Command-Shift-[ does, and tells VoiceOver which tab shows now.
    func selectPrevious() {
        noteKeyboardFocus()
        isShowingConnection = false
        tabs.selectPrevious()
        announceSelectedTab()
    }

    var hasSeveralTabs: Bool { tabs.tabs.count > 1 }

    /// Closes `tab`, and tells VoiceOver, with the tab that shows now if it was the selected one.
    /// Closing the last one goes back to the host list.
    func close(_ tab: TerminalTab<TerminalController>) {
        let wasSelected = tab.id == tabs.selectedTabID
        if wasSelected {
            noteKeyboardFocus()
            isShowingConnection = false
        }
        let name = name(of: tab)
        tabs.close(tab)
        if tabs.tabs.isEmpty {
            hideTerminals()
            announce("Closed \(name)")
        } else if wasSelected, let shown = spokenSelectedTab {
            announce("Closed \(name). \(shown)")
        } else {
            announce("Closed \(name)")
        }
    }

    /// The selected tab as VoiceOver hears it after a switch from the keyboard: "web-01 (2), tab 2
    /// of 3", and how its connection is unless it works.
    private var spokenSelectedTab: String? {
        guard let tab = selectedTab, let index = tabs.tabs.firstIndex(where: { $0.id == tab.id }) else {
            return nil
        }
        var parts = [name(of: tab), "tab \(index + 1) of \(tabs.tabs.count)"]
        if tab.state != .active {
            parts.append(TabStatusSymbol.spokenState(tab.state))
        }
        return parts.joined(separator: ", ")
    }

    private func announceSelectedTab() {
        if let shown = spokenSelectedTab {
            announce(shown)
        }
    }

    /// Command-W closes what is in front: the connection sheet while it is up, then the selected
    /// tab's question, then the tab itself. Esc is the program's, and a program never gets Command-W.
    func closeFrontmost() {
        guard let tab = selectedTab else { return }
        if isShowingConnection {
            isShowingConnection = false
        } else if tab.prompt != nil {
            tab.dismissPrompt()
        } else if tab.hostKeyChange != nil {
            tab.hostKeyChangeDismissed()
        } else {
            close(tab)
        }
    }

    /// The tabs went: the terminal screen goes too.
    func tabsChanged() {
        if tabs.tabs.isEmpty {
            hideTerminals()
        }
    }

    /// Whether the selected terminal has the keyboard: the next one selected takes it, so that a
    /// hardware keyboard types on in the new tab.
    private func noteKeyboardFocus() {
        passesKeyboardFocus = selectedTab?.terminal.view.isFirstResponder ?? false
    }

    // MARK: - Names

    /// The name a tab goes by in the tab bar and the Live section: the window title its program set,
    /// or its host's name, with a number after it when another tab before it has the same name.
    func name(of tab: TerminalTab<TerminalController>) -> String {
        let base = Self.baseName(of: tab)
        let before = tabs.tabs.prefix { $0.id != tab.id }.filter { Self.baseName(of: $0) == base }.count
        return before == 0 ? base : "\(base) (\(before + 1))"
    }

    private static func baseName(of tab: TerminalTab<TerminalController>) -> String {
        tab.terminal.title.isEmpty ? tab.host.name : tab.terminal.title
    }

    // MARK: - The app

    /// The window became active, inactive or went to the background.
    func scenePhaseChanged(_ phase: ScenePhase) {
        isSceneActive = phase == .active
        switch phase {
        case .active:
            closingInBackground?.cancel()
            closingInBackground = nil
            endBackgroundTask()
            tabs.enterForeground()
        case .background:
            enterBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
        updateCanConnect()
    }

    /// App lock engaged or let the user in: tabs reconnect only once Shello is unlocked, through the
    /// unlock window, so that a return to Shello costs at most one prompt (README section 13).
    func lockChanged(isLocked: Bool) {
        self.isLocked = isLocked
        updateCanConnect()
    }

    private func updateCanConnect() {
        tabs.canConnect = isSceneActive && !isLocked
    }

    /// Keeps the connections for the background time iOS grants, then closes them cleanly (README
    /// section 4). A background task asks for that time; nothing else keeps Shello running.
    private func enterBackground() {
        guard tabs.tabs.contains(where: { $0.state == .active || $0.state.isConnecting }) else { return }
        let application = UIApplication.shared
        if backgroundTask == .invalid {
            backgroundTask = application.beginBackgroundTask(withName: "Close connections") { [weak self] in
                // The background time ran out before the connections closed: they close now.
                MainActor.assumeIsolated { self?.backgroundTimeExpired() }
            }
        }
        let delay = backgroundTime ?? Self.closeDelay(remaining: application.backgroundTimeRemaining)
        Self.logger.info("In the background: the connections close in \(delay)")
        closingInBackground?.cancel()
        closingInBackground = Task {
            await tabs.enterBackground(closingConnectionsAfter: delay)
            endBackgroundTask()
        }
    }

    /// How long the connections stay in the background: what iOS grants, about 30 seconds, less
    /// five for their clean close, and at most 25.
    static func closeDelay(remaining: TimeInterval) -> Duration {
        let seconds = remaining.isFinite ? min(remaining - 5, 25) : 25
        return .seconds(max(seconds, 0))
    }

    private func backgroundTimeExpired() {
        closingInBackground?.cancel()
        closingInBackground = nil
        let tabs = tabs
        Task { await tabs.closeConnections() }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - VoiceOver

    /// Tells VoiceOver what the selected tab's connection did, as it does it: the screen changes
    /// above the terminal, where VoiceOver may not be. A connection that runs a plain shell instead
    /// of the host's tmux session says why here, as an announcement of its own would be cut off by
    /// this one.
    func stateChanged(of tab: TerminalTab<TerminalController>, from old: TabState, to new: TabState) {
        let host = tab.host.name
        let note = tab.plainShellNote.map { ". \($0)" } ?? ""
        switch (old, new) {
        case (.connecting, .active):
            announce("Connected to \(host)\(note)")
        case (_, .active):
            announce("Reconnected to \(host)\(note)")
        case (.active, .reconnecting):
            announce("Connection lost. Reconnecting to \(host)")
        case (_, .ended):
            announce("Connection closed")
        case (_, .disconnected(let reason)):
            announce(reason)
        default:
            break
        }
    }

    /// VoiceOver hears the screen open; a connection that takes a while says so.
    private func announceSlowConnection(of tab: TerminalTab<TerminalController>) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, tab.id == self.tabs.selectedTabID, tab.state.isConnecting, tab.prompt == nil else {
                return
            }
            announce("Connecting to \(tab.host.name)", priority: .low)
        }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Tabs")
}
