import Foundation
import ShelloModel

/// The tabs a window offers to restore after Shello was terminated (GLOSSARY: Restore): of the tabs
/// it remembers, those whose host Shello still has, as the host is now, in their order, and the
/// selected one among them. A tab whose host was deleted since is left out, and counted, so that
/// the offer can say so.
public struct RestoreOffer: Hashable, Sendable {
    /// A tab to restore.
    public struct Tab: Identifiable, Hashable, Sendable {
        /// The same while the offer shows, whatever happens to the host or to the other tabs.
        public let id: UUID
        public let host: Host
    }

    /// The tabs to restore, in their order.
    public let tabs: [Tab]
    /// The selected tab's place among them. When the selected tab's host was deleted, the tab after
    /// it, or the one before it for the last, as closing a tab moves the selection.
    public let selectedIndex: Int?
    /// How many of the remembered tabs are left out, because their host was deleted.
    public let deletedHostCount: Int

    /// What `remembered` offers, with the hosts Shello has saved, `saved`, by identifier.
    public init(_ remembered: RememberedTabs, hosts saved: [Host.ID: Host]) {
        self.init(
            remembered.hostIDs.map { (id: UUID(), hostID: $0) }, selectedIndex: remembered.selectedIndex,
            hosts: saved, deletedHostCount: 0)
    }

    /// The tabs of `candidates` whose host is among `saved`; those that are not are left out, and
    /// counted with `deletedHostCount`.
    private init(
        _ candidates: [(id: UUID, hostID: Host.ID)], selectedIndex selected: Int?, hosts saved: [Host.ID: Host],
        deletedHostCount: Int
    ) {
        var tabs: [Tab] = []
        var selectedIndex: Int?
        for (index, candidate) in candidates.enumerated() {
            if index == selected {
                // The tab itself if its host is kept, or else the next one that is.
                selectedIndex = tabs.count
            }
            if let host = saved[candidate.hostID] {
                tabs.append(Tab(id: candidate.id, host: host))
            }
        }
        // Past the last tab kept: the last one.
        let lastIndex = tabs.count - 1
        self.init(
            tabs: tabs, selectedIndex: selectedIndex.flatMap { lastIndex >= 0 ? min($0, lastIndex) : nil },
            deletedHostCount: deletedHostCount + candidates.count - tabs.count)
    }

    private init(tabs: [Tab], selectedIndex: Int?, deletedHostCount: Int) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.deletedHostCount = deletedHostCount
    }

    /// The host of each tab, in the tabs' order.
    public var hosts: [Host] { tabs.map(\.host) }

    /// Whether there is nothing to restore: every remembered tab's host was deleted.
    public var isEmpty: Bool { tabs.isEmpty }

    /// The offer with its hosts as Shello has them saved now, `saved`: the tabs whose host was
    /// deleted meanwhile are left out, and counted with the others.
    public func updated(with saved: [Host.ID: Host]) -> RestoreOffer {
        RestoreOffer(
            tabs.map { (id: $0.id, hostID: $0.host.id) }, selectedIndex: selectedIndex, hosts: saved,
            deletedHostCount: deletedHostCount)
    }

    /// The offer once the tab `id` was restored on its own: without it, the others in their order.
    /// Once the selected tab is restored, the others select none of theirs.
    public func removingTab(_ id: Tab.ID) -> RestoreOffer {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return self }
        var tabs = tabs
        tabs.remove(at: index)
        let selected: Int? =
            switch selectedIndex {
            case let selected? where selected > index: selected - 1
            case let selected? where selected < index: selected
            default: nil
            }
        return RestoreOffer(tabs: tabs, selectedIndex: selected, deletedHostCount: deletedHostCount)
    }
}
