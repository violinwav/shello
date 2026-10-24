import Foundation
import Observation
import ShelloModel
import ShelloStorage

/// The tabs of a window (README section 4): several at once, several per host, one of them
/// selected, which is the one on screen while the terminal screen shows.
///
/// They follow Shello's foreground, background and lock, and the device's network:
/// - In the background, the connections stay for the short time iOS grants, then close cleanly
///   (`enterBackground(closingConnectionsAfter:)`). No audio, location or VoIP mode keeps them.
/// - Back in the foreground, the tab on screen reconnects at once, and each other tab once it is
///   selected, since nothing ran while Shello was suspended. Their terminals keep their scrollback.
///   Shello must be unlocked first, so that a return costs at most one Face ID prompt: reconnecting
///   uses the unlock window.
/// - While the device has no network, a tab that lost its connection waits for it, and reconnects
///   as soon as it is back.
@MainActor
@Observable
public final class TerminalTabs<Terminal: TabTerminal> {
    public private(set) var tabs: [TerminalTab<Terminal>] = []
    public private(set) var selectedTabID: TerminalTab<Terminal>.ID?

    /// Whether the selected tab is on screen. A tab whose connection Shello closed in the
    /// background reconnects once it is.
    public var isOnScreen = false {
        didSet {
            if isOnScreen, !oldValue { resumeSelectedTab() }
        }
    }

    /// Whether the tabs may connect: Shello is in the foreground and unlocked. Set by the screens.
    public var canConnect: Bool {
        get { conditions.canConnect }
        set {
            guard newValue != conditions.canConnect else { return }
            conditions.canConnect = newValue
            conditionsChanged()
            if newValue { resumeSelectedTab() }
        }
    }

    /// Whether the device has a network, as `NetworkMonitor` last said.
    public var isNetworkAvailable: Bool { conditions.isNetworkAvailable }

    @ObservationIgnored private let services: TabServices
    @ObservationIgnored private let makeTerminal: @MainActor (Host) -> Terminal
    @ObservationIgnored private let conditions = TabConditions()
    @ObservationIgnored private var networkUpdates: Task<Void, Never>?
    @ObservationIgnored private var backgroundClose: Task<Void, Never>?

    /// Tabs that connect through `services`, each with a terminal of its own from `makeTerminal`.
    public init(services: TabServices, makeTerminal: @escaping @MainActor (Host) -> Terminal) {
        self.services = services
        self.makeTerminal = makeTerminal
    }

    isolated deinit {
        networkUpdates?.cancel()
        backgroundClose?.cancel()
    }

    public var selectedTab: TerminalTab<Terminal>? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Opens a new tab for `host`, after the selected one, selects it, and connects (README section
    /// 4). A host can have several tabs.
    @discardableResult
    public func open(_ host: Host) -> TerminalTab<Terminal> {
        let tab = TerminalTab(
            host: host, terminal: makeTerminal(host), services: services, conditions: conditions,
            declined: { [weak self] tab in self?.remove(tab) })
        let index = tabs.firstIndex { $0.id == selectedTabID }.map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(tab, at: index)
        selectedTabID = tab.id
        watchNetwork()
        tab.start()
        return tab
    }

    /// Selects `tab`. A tab whose connection Shello closed in the background reconnects, once it is
    /// on screen.
    public func select(_ tab: TerminalTab<Terminal>) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        selectedTabID = tab.id
        resumeSelectedTab()
    }

    /// Selects the tab after the selected one, or the first after the last.
    public func selectNext() {
        selectNeighbour(by: 1)
    }

    /// Selects the tab before the selected one, or the last before the first.
    public func selectPrevious() {
        selectNeighbour(by: -1)
    }

    private func selectNeighbour(by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs.count > 1 else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Closes `tab`: it leaves the tabs at once, the tab after it selected, or the one before for
    /// the last, and its connection ends without waiting for the user, Face ID included. The task
    /// returned ends once the connection has.
    @discardableResult
    public func close(_ tab: TerminalTab<Terminal>) -> Task<Void, Never> {
        remove(tab)
        return tab.close()
    }

    private func remove(_ tab: TerminalTab<Terminal>) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            resumeSelectedTab()
        }
        if tabs.isEmpty {
            // Nothing runs while no tab is open (README section 16).
            networkUpdates?.cancel()
            networkUpdates = nil
        }
    }

    // MARK: - Foreground and background

    /// Shello went to the background: the connections stay for `delay`, the short time iOS grants,
    /// then close cleanly, unless Shello comes back first (README section 4). Returns once they are
    /// closed, or Shello is back.
    public func enterBackground(closingConnectionsAfter delay: Duration) async {
        backgroundClose?.cancel()
        let sleep = services.sleep
        let close = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self?.closeConnections()
        }
        backgroundClose = close
        await close.value
    }

    /// Closes every tab's connection now, cleanly, as when the background time runs out. Each tab
    /// reconnects once it is on screen again.
    public func closeConnections() async {
        await withDiscardingTaskGroup { group in
            for tab in tabs {
                group.addTask { await tab.suspend() }
            }
        }
    }

    /// Shello is back in the foreground. Connections that the background time left open stay; the
    /// tab on screen reconnects at once if Shello closed its connection, once Shello is unlocked.
    public func enterForeground() {
        backgroundClose?.cancel()
        backgroundClose = nil
        resumeSelectedTab()
    }

    private func resumeSelectedTab() {
        guard isOnScreen, canConnect, let tab = selectedTab else { return }
        tab.resume()
    }

    // MARK: - The network

    private func watchNetwork() {
        guard networkUpdates == nil else { return }
        let updates = services.network.updates()
        networkUpdates = Task { [weak self] in
            for await isAvailable in updates {
                guard let self else { return }
                guard isAvailable != self.conditions.isNetworkAvailable else { continue }
                self.conditions.isNetworkAvailable = isAvailable
                self.conditionsChanged()
            }
        }
    }

    private func conditionsChanged() {
        for tab in tabs {
            tab.conditionsChanged()
        }
    }
}

/// What tabs connect with, and how they wait: the app's own, or stand-ins in tests.
public struct TabServices: Sendable {
    public var connector: any TabConnector
    /// Where each connection is recorded, for Recents (README section 3). Nil records nothing.
    public var hosts: HostRepository?
    public var network: any NetworkMonitor
    public var reconnectPolicy: ReconnectPolicy
    /// How long a connection whose network went may wait for it to come back before the tab
    /// reconnects.
    public var viabilityGrace: Duration
    /// Waits, for the reconnect policy, the keepalive and the background time. Tests make it quick.
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        connector: any TabConnector, hosts: HostRepository? = nil, network: any NetworkMonitor = SystemNetworkMonitor(),
        reconnectPolicy: ReconnectPolicy = .standard, viabilityGrace: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.connector = connector
        self.hosts = hosts
        self.network = network
        self.reconnectPolicy = reconnectPolicy
        self.viabilityGrace = viabilityGrace
        self.sleep = sleep
    }

    /// `host` as it is stored now, so that a reconnect takes the user's edits, such as a new port;
    /// as it was, when it cannot be read or was deleted.
    func refreshedHost(_ host: Host) async -> Host {
        guard let hosts else { return host }
        return (try? await hosts.host(id: host.id)) ?? host
    }

    /// The route to `host` (README section 3), through its jump hosts as they are stored now, so
    /// that a reconnect takes the user's edits to them too. A host without jump hosts is its own
    /// route.
    /// - Throws: `RouteError` for a route Shello refuses, such as one with a jump host that was
    ///   deleted, which is never left out; or what reading the hosts throws.
    func route(to host: Host) async throws -> Route {
        guard !host.jumpHostIDs.isEmpty else { return try Route(to: host, hosts: [:]) }
        guard let hosts else { throw RouteError.missingJumpHost(of: host.name) }
        let saved = try await hosts.hosts()
        return try Route(
            to: host, hosts: Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    }
}

/// What a tab waits for before it reconnects: Shello unlocked in the foreground, and a network.
@MainActor
final class TabConditions {
    var canConnect = true
    var isNetworkAvailable = true
}
