import UIKit

/// The colours of the Shello keyboard and the extra keys row. They follow the terminal's theme,
/// not the app's appearance: a dark theme such as Night, the UI design's, gets the design's dark
/// keyboard in light mode too, as the system keyboard over the terminal is dark; a light theme gets
/// a light keyboard. Every label keeps at least 4.5:1 contrast with its key.
nonisolated struct KeyboardPalette: Equatable {
    var isDark: Bool
    var background: UIColor
    var key: UIColor
    var pressedKey: UIColor
    /// Shift, Delete, the layer keys and the extra keys row.
    var systemKey: UIColor
    var label: UIColor
    var systemLabel: UIColor
    /// Corner symbols and Space's name.
    var secondaryLabel: UIColor
    /// Return's key, and a modifier that is on.
    var accent: UIColor
    var onAccent: UIColor
    /// The Control combinations' labels.
    var accentLabel: UIColor
    /// Shift while it is on.
    var activeKey: UIColor
    var onActiveKey: UIColor
    /// The swipe key's ring.
    var ring: UIColor
    var callout: UIColor
    var shadow: UIColor

    /// The palette for `theme`: dark for a theme with a dark background.
    static func forTheme(_ theme: TerminalTheme) -> KeyboardPalette {
        let accent = theme.accent.uiColor
        let onAccent = theme.onAccent.uiColor
        if theme.isDark {
            return KeyboardPalette(
                isDark: true, background: color(0x141619), key: color(0x2B2E33), pressedKey: color(0x474B53),
                systemKey: color(0x1F2226), label: color(0xEDEFF2), systemLabel: color(0xC7CCD2),
                // The design's #8A9098 is 4.2:1 on a key; the design's second text colour is 5.8:1.
                secondaryLabel: color(0xA3A9B1), accent: accent, onAccent: onAccent, accentLabel: accent,
                activeKey: color(0xEDEFF2), onActiveKey: color(0x0A0B0D), ring: color(0x353940),
                callout: color(0x3A3E45),
                shadow: UIColor(white: 0, alpha: 0.65))
        }
        return KeyboardPalette(
            isDark: false, background: color(0xD3D6DB), key: color(0xFFFFFF), pressedKey: color(0xE4E7EB),
            systemKey: color(0xB9BEC6), label: color(0x111316), systemLabel: color(0x111316),
            secondaryLabel: color(0x4A5058), accent: accent, onAccent: onAccent,
            // On white, the accent as text is darkened to 52 %, as the design's light accent ink.
            accentLabel: theme.accent.scaled(by: 0.52).uiColor, activeKey: color(0x111316),
            onActiveKey: color(0xFFFFFF),
            ring: color(0x9EA4AD), callout: color(0xFFFFFF), shadow: UIColor(white: 0, alpha: 0.25))
    }

    private static func color(_ hex: UInt32) -> UIColor {
        TerminalTheme.RGB(hex).uiColor
    }
}

extension TerminalTheme {
    /// Whether the theme's background is dark, which decides the keyboard's colours.
    nonisolated var isDark: Bool {
        let rgb = background
        // Rec. 709 luma: close enough to tell a dark background from a light one.
        let luma = 0.2126 * Double(rgb.red) + 0.7152 * Double(rgb.green) + 0.0722 * Double(rgb.blue)
        return luma < 128
    }
}

extension TerminalTheme.RGB {
    /// The colour with each component multiplied by `factor`.
    nonisolated func scaled(by factor: Double) -> TerminalTheme.RGB {
        func scale(_ value: UInt8) -> UInt32 { UInt32((Double(value) * factor).rounded()) }
        return TerminalTheme.RGB(scale(red) << 16 | scale(green) << 8 | scale(blue))
    }
}
