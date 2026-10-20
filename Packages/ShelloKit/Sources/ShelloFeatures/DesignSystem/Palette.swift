import ShelloModel
import SwiftUI

/// The colour tokens of the UI design (docs/ui/ui_v1/README.md). Each is a colour set in
/// Colors.xcassets with a light and a dark variant. Text tokens keep at least 4.5:1 contrast on the
/// surfaces they are drawn on, in both appearances.
enum Palette {
    // Surfaces
    static let ground = color("Ground")
    static let cell = color("Cell")
    static let tile = color("Tile")
    static let hairline = color("Hairline")

    // Text
    static let textPrimary = color("TextPrimary")
    static let textSecondary = color("TextSecondary")
    static let textTertiary = color("TextTertiary")

    /// Tiffany, the default accent. Fills only; text in the accent colour uses `accentInk`.
    static let accent = color("Accent")
    /// The accent for text and tinted controls: Tiffany in dark mode, darkened to 52 % in light mode
    /// for contrast.
    static let accentInk = color("AccentInk")
    /// Text and symbols on an accent fill.
    static let onAccent = color("OnAccent")
    /// The accent darkened to 52 % in both appearances, for fills whose symbol the system draws in
    /// a light colour, such as a prominent toolbar button: 7.3:1 with white.
    static let accentDeep = color("AccentDeep")

    // Status
    static let statusError = color("StatusError")

    static func tag(_ tagColor: Tag.Color) -> Color {
        color(assetName(of: tagColor))
    }

    /// The colour set for a tag colour. The design draws a tag in a different shade per appearance.
    static func assetName(of tagColor: Tag.Color) -> String {
        switch tagColor {
        case .red: "TagRed"
        case .orange: "TagOrange"
        case .yellow: "TagYellow"
        case .green: "TagGreen"
        case .blue: "TagBlue"
        case .purple: "TagPurple"
        case .gray: "TagGray"
        }
    }

    private static func color(_ name: String) -> Color {
        Color(name, bundle: DesignSystem.resourceBundle)
    }
}

extension Tag.Color {
    /// The colour's name. Wherever a tag's colour appears, its name or the tag's name does too, so
    /// that colour is never the only signal.
    var displayName: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }
}
