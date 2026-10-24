import Foundation

/// The tabs a window has open, as Restore recreates them after Shello was terminated (GLOSSARY:
/// Restore): the host of each tab, in the tabs' order, and which tab is selected. Nothing else:
/// not what the terminals showed, which goes with Shello, and nothing secret.
public struct RememberedTabs: Hashable, Sendable, Codable {
    /// The host of each tab, in the tabs' order. A host can have several tabs.
    public let hostIDs: [Host.ID]
    /// The selected tab's place among them, or nil if none is selected.
    public let selectedIndex: Int?

    /// Tabs of the hosts `hostIDs`, in their order, the one at `selectedIndex` selected. A place that
    /// is not one of theirs selects none.
    public init(hostIDs: [Host.ID], selectedIndex: Int?) {
        self.hostIDs = hostIDs
        self.selectedIndex = selectedIndex.flatMap { hostIDs.indices.contains($0) ? $0 : nil }
    }

    /// No tabs: a window whose last tab was closed restores nothing.
    public static let empty = RememberedTabs(hostIDs: [], selectedIndex: nil)

    public var isEmpty: Bool { hostIDs.isEmpty }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostIDs: try container.decode([Host.ID].self, forKey: .hostIDs),
            selectedIndex: try container.decodeIfPresent(Int.self, forKey: .selectedIndex))
    }
}
