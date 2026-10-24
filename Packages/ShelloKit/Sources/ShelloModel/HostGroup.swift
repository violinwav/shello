import Foundation

/// The one group a host belongs to, if any. Groups do not nest.
public struct HostGroup: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
