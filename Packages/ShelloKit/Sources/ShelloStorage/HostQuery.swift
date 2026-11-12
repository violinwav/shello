import GRDB
import ShelloModel

/// Which hosts to read, and in which order (README section 3).
public struct HostQuery: Hashable, Sendable {
    /// Words to look for in each host's name, address, username and tag names, ignoring case and
    /// diacritics the way the system's own search does. A host matches when it contains every
    /// word. An empty search matches every host.
    public var search: String
    public var order: HostOrder

    public init(search: String = "", order: HostOrder = .name) {
        self.search = search
        self.order = order
    }
}

/// The order of a host list.
public enum HostOrder: Hashable, Sendable, CaseIterable {
    /// By name, then username, then address.
    case name
    /// Favourites first, each part by name.
    case favorites
    /// The most recently connected first, then the hosts Shello never connected to, by name.
    case recents
}

extension HostQuery {
    /// The request for the hosts this query selects, tombstones included.
    var request: QueryInterfaceRequest<HostRecord> {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        var request = HostRecord.all()
        for word in words {
            request = request.filter(
                literal: """
                    (localizedStandardContains(host.name, \(word))
                    OR localizedStandardContains(host.address, \(word))
                    OR localizedStandardContains(host.username, \(word))
                    OR EXISTS (
                        SELECT 1 FROM hostTag JOIN tag ON tag.id = hostTag.tagID
                        WHERE hostTag.hostID = host.id AND tag.deletedAt IS NULL
                        AND localizedStandardContains(tag.name, \(word))))
                    """)
        }
        return request.order(order.orderings)
    }
}

extension HostOrder {
    var orderings: [any SQLOrderingTerm] {
        let byName: [any SQLOrderingTerm] = [
            HostRecord.Columns.name.collating(.localizedStandardCompare),
            HostRecord.Columns.username.collating(.localizedStandardCompare),
            HostRecord.Columns.address.collating(.localizedStandardCompare),
            HostRecord.Columns.id,
        ]
        switch self {
        case .name: return byName
        case .favorites: return [HostRecord.Columns.isFavorite.desc] + byName
        // SQLite sorts NULL below every value, so descending puts never-connected hosts last.
        case .recents: return [HostRecord.Columns.lastConnectedAt.desc] + byName
        }
    }
}
