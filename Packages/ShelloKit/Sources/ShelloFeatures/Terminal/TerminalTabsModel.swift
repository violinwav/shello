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
/// - The window remembers its tabs as they change (`RememberedTabsStore`). When it appears after
///   Shello was terminated, the Live section offers the tabs it had open, and nothing connects until
///   the user restores them, all or one, or dismisses them (GLOSSARY: Restore).
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

    /// The tabs the window had open when Shello was terminated, which the Live section offers to
    /// restore until the user restores or dismisses them. Nil when there are none.
    private(set) var restoreOffer: RestoreOffer?

    @ObservationIgnored private let settings: TerminalSettings?
    @ObservationIgnored private let hosts: HostRepository?
    @ObservationIgnored private let rememberedTabs: RememberedTabsStore?
    /// The window's scene session, under which its tabs are remembered, once the window appeared.
    @ObservationIgnored private var windowID: String?
    /// Follows the saved hosts while the offer shows.
    @ObservationIgnored private var offerUpdates: Task<Void, Never>?
    /// How long the connections stay in the background: nil for what iOS grants.
    @ObservationIgnored private let backgroundTime: Duration?
    @ObservationIgnored private var isSceneActive = false
    @ObservationIgnored private var isLocked = false
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var closingInBackground: Task<Void, Never>?
    /// Whether the terminal that was selected last had the keyboard, which the next one takes.
    @ObservationIgnored private(set) var passesKeyboardFocus = false
    /// The tab the user opened last, with Connect, New Tab or Restore: VoiceOver goes to its terminal
    /// once it connects. A tab that connects once it is selected, after the background or after
    /// Restore, leaves VoiceOver where it is.
    @ObservationIgnored private(set) var tabOpenedByTheUser: UUID?

    /// Tabs that connect with `connector` and record their connections in `hosts`, with terminals
    /// made with `settings`, remembered in `rememberedTabs` for Restore. `backgroundTime` replaces the
    /// background time iOS grants, for the UI tests.
    init(
        connector: HostConnector, hosts: HostRepository?, settings: TerminalSettings?,
        rememberedTabs: RememberedTabsStore? = nil, backgroundTime: Duration? = nil
    ) {
        self.settings = settings
        self.hosts = hosts
        self.rememberedTabs = rememberedTabs
        self.backgroundTime = backgroundTime
        let preferences = { settings?.preferences ?? TerminalPreferences() }
        tabs = TerminalTabs(services: TabServices(connector: connector, hosts: hosts)) { _ in
            TerminalController(preferences: preferences(), theme: .night, typeface: DesignSystem.terminalTypeface)
        }
    }

    isolated deinit {
        offerUpdates?.cancel()
    }

    var selectedTab: TerminalTab<TerminalController>? { tabs.selectedTab }

    // MARK: - Tabs

    /// Opens a tab for `host` and shows it (README section 4).
    func connect(to host: Host) {
        noteKeyboardFocus()
        isShowingConnection = false
        let tab = tabs.open(host)
        tabOpenedByTheUser = tab.id
        announceSlowConnection(of: tab)
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
        } else if let prompt = tab.prompt {
            tab.dismissPrompt(prompt)
        } else if let change = tab.hostKeyChange {
            tab.hostKeyChangeDismissed(change)
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

    // MARK: - Restore

    /// The window is on screen, in the scene session `id`: from now on its tabs are remembered under
    /// it as they change, and the tabs it had open when Shello was terminated are offered. Only the
    /// first time counts: while the window's tabs live, there is nothing to restore, as when Shello
    /// comes back to the foreground with them (README section 4).
    func windowAppeared(_ id: String) {
        guard windowID == nil, let rememberedTabs else { return }
        windowID = id
        let remembered = rememberedTabs.windowAppeared(id)
        tabs.onRememberedTabsChange = { [weak self] remembered in self?.remember(remembered) }
        guard !remembered.isEmpty else { return }
        offerUpdates = Task { [weak self] in await self?.offer(remembered) }
    }

    /// Offers `remembered`, with their hosts as they are saved, and follows the saved hosts while the
    /// offer shows: a host deleted meanwhile leaves it, so that its tab is never restored. With no
    /// host left, nothing is offered, nor remembered any more.
    private func offer(_ remembered: RememberedTabs) async {
        guard let hosts else { return }
        var isFirst = true
        do {
            for try await saved in hosts.observeHosts() {
                guard !Task.isCancelled else { return }
                let byID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let offer = isFirst ? RestoreOffer(remembered, hosts: byID) : restoreOffer?.updated(with: byID)
                isFirst = false
                guard let offer, !offer.isEmpty else {
                    endOffer()
                    remember(tabs.remembered)
                    return
                }
                restoreOffer = offer
            }
        } catch is CancellationError {
        } catch {
            Self.logger.error("Could not read the hosts of the tabs to restore: \(error)")
        }
    }

    /// The name the offered tab would go by once restored: its host's, with a number after it when
    /// a tab before it, open or offered, goes by that name too, as in "nas (2)". Restored tabs come
    /// after the open ones, so that no open tab's name changes.
    func name(ofOffered tab: RestoreOffer.Tab) -> String {
        let name = tab.host.name
        let open = tabs.tabs.filter { Self.baseName(of: $0) == name }.count
        let offered = (restoreOffer?.tabs ?? []).prefix { $0.id != tab.id }.filter { $0.host.name == name }.count
        let before = open + offered
        return before == 0 ? name : "\(name) (\(before + 1))"
    }

    /// The offered tabs' names, in their order (`name(ofOffered:)`).
    var offeredTabNames: [String] {
        (restoreOffer?.tabs ?? []).map(name(ofOffered:))
    }

    /// The place of the offered tab that connects at once if all are restored: the selected one, or
    /// the first while no tab is open; nil when an open tab stays selected, and none does.
    var offeredTabConnectingAtOnce: Int? {
        guard let offer = restoreOffer else { return nil }
        return offer.selectedIndex ?? (selectedTab == nil ? 0 : nil)
    }

    /// Restores every offered tab, in their order, and shows them with the same tab selected, which
    /// connects at once; each of the others connects once it is selected (README section 4), so that
    /// restoring costs at most one Face ID prompt.
    func restoreAll() {
        guard let offer = restoreOffer else { return }
        restore(offer.hosts, selecting: offer.selectedIndex)
    }

    /// Restores the offered tab `id` alone: it opens after the open tabs, connects and shows, and
    /// the others stay offered.
    func restoreTab(_ id: RestoreOffer.Tab.ID) {
        guard let offer = restoreOffer, let tab = offer.tabs.first(where: { $0.id == id }) else { return }
        let rest = offer.removingTab(id)
        restore([tab.host], selecting: 0, offering: rest.isEmpty ? nil : rest)
    }

    /// Restores tabs for `hosts`, selecting the one at `selected`, and shows them; `rest` stays
    /// offered.
    private func restore(_ hosts: [Host], selecting selected: Int?, offering rest: RestoreOffer? = nil) {
        if let rest {
            restoreOffer = rest
        } else {
            endOffer()
        }
        noteKeyboardFocus()
        isShowingConnection = false
        let wasSelected = tabs.selectedTabID
        tabs.restore(hosts, selecting: selected)
        if let tab = selectedTab, tab.id != wasSelected {
            tabOpenedByTheUser = tab.id
            announceSlowConnection(of: tab)
        }
        isShowingTerminals = true
    }

    /// Forgets the offered tabs: the window remembers what it has open now, so that the next launch
    /// offers them no more.
    func dismissRestoreOffer() {
        guard restoreOffer != nil else { return }
        endOffer()
        remember(tabs.remembered)
    }

    private func endOffer() {
        offerUpdates?.cancel()
        offerUpdates = nil
        restoreOffer = nil
    }

    private func remember(_ remembered: RememberedTabs) {
        guard let windowID else { return }
        rememberedTabs?.remember(remembered, ofWindow: windowID)
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
            announce("Connection lost. Reconnecting to \(tab.hostAlongRoute)")
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
            announce("Connecting to \(tab.hostAlongRoute)", priority: .low)
        }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Tabs")
}

extension TerminalTab {
    /// The tab's host as the texts about its whole route name it: through its jump hosts, as
    /// "web-01 through bastion", or alone (README section 3).
    var hostAlongRoute: String {
        JumpHostDisplay.host(host.name, through: route?.jumpHosts.map(\.name) ?? [])
    }
}
