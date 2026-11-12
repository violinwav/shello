import Foundation

/// A label on a host. A host can have any number of tags.
public struct Tag: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: Color

    public init(id: UUID = UUID(), name: String, color: Color) {
        self.id = id
        self.name = name
        self.color = color
    }

    /// A tag's colour comes from a fixed palette, so that the interface can pick a shade per
    /// appearance: the UI design draws the same tag in a different shade in light and dark mode.
    public enum Color: Hashable, Sendable, CaseIterable {
        case red
        case orange
        case yellow
        case green
        case blue
        case purple
        case gray
    }
}
