import UIKit

/// The user's settings for every terminal (README section 5) and its Shello keyboard (section 6),
/// which Settings changes. The font size changes with pinch and the font size shortcuts too.
nonisolated public struct TerminalPreferences: Equatable, Sendable {
    /// How many lines scrolled off the top a terminal keeps for scrolling back and search.
    public var scrollbackLines: Int
    /// Whether the Option key works as Meta: Option-x sends Esc then x, which Emacs and the shell's
    /// line editor understand, instead of typing the character Option makes.
    public var optionAsMeta: Bool
    /// A key that sends Esc, for hardware keyboards without one.
    public var escapeKey: EscapeKey
    /// Whether VoiceOver reads new output aloud (README section 16). Only while VoiceOver runs.
    public var announcesOutput: Bool
    /// The terminal's font size in points, in whole points within `fontSizes`. The terminal's text
    /// does not follow Dynamic Type: its size is set separately (README section 16).
    public var fontSize: CGFloat {
        didSet { fontSize = Self.clampedFontSize(fontSize) }
    }
    /// The Shello keyboard's settings (README section 6).
    public var keyboard: KeyboardPreferences
    /// Whether the cursor blinks. Reduce Motion stops it anyway (README section 16). UI tests stop
    /// it too: XCUITest waits for the app to go idle before each step, and a blinking cursor never
    /// lets it.
    public var cursorBlinks: Bool

    public init(
        scrollbackLines: Int = TerminalPreferences.defaultScrollbackLines, optionAsMeta: Bool = true,
        escapeKey: EscapeKey = .none, announcesOutput: Bool = true,
        fontSize: CGFloat = TerminalPreferences.defaultFontSize, keyboard: KeyboardPreferences = KeyboardPreferences(),
        cursorBlinks: Bool = true
    ) {
        self.scrollbackLines = scrollbackLines
        self.optionAsMeta = optionAsMeta
        self.escapeKey = escapeKey
        self.announcesOutput = announcesOutput
        self.fontSize = Self.clampedFontSize(fontSize)
        self.keyboard = keyboard
        self.cursorBlinks = cursorBlinks
    }

    /// 10,000 lines per tab (README section 5).
    public static let defaultScrollbackLines = 10_000
    /// The scrollback lengths Settings offers. 10 tabs with full scrollback must stay under 200 MB
    /// (README section 16), so the longest is only twice the default.
    public static let scrollbackChoices = [1_000, 5_000, 10_000, 20_000]

    /// The UI design's default text size.
    public static let defaultFontSize: CGFloat = 13
    /// How small and how large pinch and the shortcuts make the terminal's text.
    public static let fontSizes: ClosedRange<CGFloat> = 8...32

    /// `size` rounded to a whole point inside `fontSizes`: a terminal resizes its grid on every
    /// change of font size, so it changes in whole points.
    public static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return defaultFontSize }
        return min(max(size.rounded(), fontSizes.lowerBound), fontSizes.upperBound)
    }
}

/// A key that sends Esc on a hardware keyboard without an Esc key, such as the iPad's keyboards
/// (README section 5). Control-[ always sends Esc as well, and the system can make Caps Lock an
/// Esc key for every app. Caps Lock is not offered here: iOS switches capitals on and off with it
/// whatever the app does with the key.
nonisolated public enum EscapeKey: String, CaseIterable, Identifiable, Sendable {
    /// Only the keyboard's own Esc key.
    case none
    /// Command-period, the Mac's Cancel shortcut.
    case commandPeriod
    /// The key left of 1, `` ` `` and ~ on a US keyboard, when pressed without a modifier. Shift
    /// still types its other character.
    case graveAccent

    public var id: Self { self }

    /// Whether the key `keyCode`, pressed with `modifiers`, sends Esc.
    public func sendsEscape(keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool {
        // Caps Lock's state is not a modifier the user is holding.
        let held = modifiers.subtracting([.alphaShift, .numericPad])
        switch self {
        case .none: return false
        case .commandPeriod: return keyCode == .keyboardPeriod && held == .command
        case .graveAccent: return keyCode == .keyboardGraveAccentAndTilde && held.isEmpty
        }
    }
}
