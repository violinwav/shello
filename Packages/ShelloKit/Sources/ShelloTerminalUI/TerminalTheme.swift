import SwiftTerm
import UIKit

/// The colours a terminal draws with: its default foreground and background, the 16 ANSI colours
/// that the 256-colour palette is derived from, the cursor and the selection.
nonisolated public struct TerminalTheme: Equatable, Sendable {
    public var foreground: RGB
    public var background: RGB
    /// Black, red, green, yellow, blue, magenta, cyan and white, then their bright variants.
    public var ansi: [RGB]
    /// The cursor, and the selection behind selected text, such as a search match.
    public var accent: RGB
    /// Text on the cursor and on the selection.
    public var onAccent: RGB

    public init(foreground: RGB, background: RGB, ansi: [RGB], accent: RGB, onAccent: RGB) {
        precondition(ansi.count == 16, "A terminal theme has 16 ANSI colours")
        self.foreground = foreground
        self.background = background
        self.ansi = ansi
        self.accent = accent
        self.onAccent = onAccent
    }

    /// Night, the UI design's default theme (docs/ui/ui_v1, Appearance), with Tiffany for the
    /// cursor. The design names the background, the text and five of the colours; the others are
    /// chosen to match them. The terminal stays dark in light mode: its theme is its own.
    public static let night = TerminalTheme(
        foreground: RGB(0xD8DCE1),
        background: RGB(0x0A0B0D),
        ansi: [
            RGB(0x2B2E33), RGB(0xFF6B5E), RGB(0x8BD17C), RGB(0xE8C46B),
            RGB(0x6CB6FF), RGB(0xB9A4FF), RGB(0x63D3D8), RGB(0xD8DCE1),
            RGB(0x7D8590), RGB(0xFF8A80), RGB(0xA6E39A), RGB(0xF2D58C),
            RGB(0x8EC8FF), RGB(0xCDBDFF), RGB(0x8FE3E7), RGB(0xF5F7F9),
        ],
        accent: RGB(0x0ABAB5),
        onAccent: RGB(0x16130B))

    /// A colour as 8-bit red, green and blue.
    nonisolated public struct RGB: Equatable, Sendable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        /// The colour written as `0xRRGGBB`.
        public init(_ hex: UInt32) {
            red = UInt8((hex >> 16) & 0xFF)
            green = UInt8((hex >> 8) & 0xFF)
            blue = UInt8(hex & 0xFF)
        }

        public var uiColor: UIColor {
            UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }

        /// SwiftTerm's colours have 16 bits per component.
        var terminalColor: SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
        }
    }
}
