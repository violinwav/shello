import Foundation
import ShelloModel

/// A section of the host list (README section 3: favourites and recents, groups, tag filters).
struct HostSection: Identifiable, Equatable {
    enum ID: Hashable {
        case favorites
        case recents
        case group(HostGroup.ID)
        case ungrouped
    }

    let id: ID
    let title: String
    let hosts: [Host]

    /// How many hosts the Recent section lists.
    static let recentsLimit = 5

    /// The host list's sections: the favourites, the hosts Shello connected to most recently, one
    /// section per group, and the hosts in no group. A favourite or recent host is also listed in
    /// its group. Sections without hosts are left out.
    /// - Parameters:
    ///   - hosts: The hosts to list, in name order.
    ///   - groups: Every group, in name order.
    ///   - tagFilter: The tag a host must have to be listed, or nil to list every host.
    static func sections(hosts: [Host], groups: [HostGroup], tagFilter: Tag.ID?) -> [HostSection] {
        let hosts = tagFilter.map { tag in hosts.filter { $0.tagIDs.contains(tag) } } ?? hosts
        var sections: [HostSection] = []

        let favorites = hosts.filter(\.isFavorite)
        if !favorites.isEmpty {
            sections.append(HostSection(id: .favorites, title: "Favorites", hosts: favorites))
        }

        // Newest first; the sort is stable, so hosts connected to at the same time stay in name order.
        let recents = hosts.filter { !$0.isFavorite && $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(recentsLimit)
        if !recents.isEmpty {
            sections.append(HostSection(id: .recents, title: "Recent", hosts: Array(recents)))
        }

        let hostsByGroup = Dictionary(grouping: hosts, by: \.groupID)
        let groupSections = groups.compactMap { group in
            hostsByGroup[group.id].map { HostSection(id: .group(group.id), title: group.name, hosts: $0) }
        }
        sections += groupSections

        // A host in a group the list does not know is listed with the hosts in no group.
        let knownGroups = Set(groups.map(\.id))
        let ungrouped = hosts.filter { host in host.groupID.map { !knownGroups.contains($0) } ?? true }
        if !ungrouped.isEmpty {
            let title = groupSections.isEmpty ? "All Hosts" : "No Group"
            sections.append(HostSection(id: .ungrouped, title: title, hosts: ungrouped))
        }
        return sections
    }
}
