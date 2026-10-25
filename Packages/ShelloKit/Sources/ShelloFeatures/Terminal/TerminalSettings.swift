import Foundation
import Observation
import ShelloTerminalUI

/// The terminal settings of this device (README section 5): the scrollback's length, Option as
/// Meta, the extra Esc key, whether VoiceOver reads new output, and the font size, which pinch and
/// the shortcuts change; and the Shello keyboard's (section 6): its letters layout, its haptics, the
/// swipe key's speed, and whether the extra keys row stays while a hardware keyboard is attached.
/// Like app lock's timeout they stay on the device, and the export leaves them out
/// (docs/spec/EXPORT.md).
@MainActor
@Observable
public final class TerminalSettings {
    public var scrollbackLines: Int {
        didSet { defaults.set(scrollbackLines, forKey: Keys.scrollbackLines) }
    }
    public var optionAsMeta: Bool {
        didSet { defaults.set(optionAsMeta, forKey: Keys.optionAsMeta) }
    }
    public var escapeKey: EscapeKey {
        didSet { defaults.set(escapeKey.rawValue, forKey: Keys.escapeKey) }
    }
    public var announcesOutput: Bool {
        didSet { defaults.set(announcesOutput, forKey: Keys.announcesOutput) }
    }
    public var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: Keys.fontSize) }
    }
    /// The letters layout, or nil to follow the first keyboard in the Settings app.
    public var keyboardLetters: LettersLayout.ID? {
        didSet { defaults.set(keyboardLetters?.rawValue, forKey: Keys.keyboardLetters) }
    }
    public var keyboardHaptics: Bool {
        didSet { defaults.set(keyboardHaptics, forKey: Keys.keyboardHaptics) }
    }
    public var swipeKeySpeed: Double {
        didSet {
            let clamped = KeyboardPreferences.clampedSwipeSpeed(swipeKeySpeed)
            if clamped != swipeKeySpeed {
                swipeKeySpeed = clamped
            }
            defaults.set(swipeKeySpeed, forKey: Keys.swipeKeySpeed)
        }
    }
    /// Whether the extra keys row stays while a hardware keyboard is attached, which hides the Shello
    /// keyboard.
    public var showsExtraKeysRowWithHardwareKeyboard: Bool {
        didSet {
            defaults.set(showsExtraKeysRowWithHardwareKeyboard, forKey: Keys.showsExtraKeysRowWithHardwareKeyboard)
        }
    }

    /// Whether the cursor blinks, which the composition root decides: Settings does not offer it,
    /// and only UI tests stop it.
    public let cursorBlinks: Bool

    private let defaults: UserDefaults

    private enum Keys {
        static let scrollbackLines = "terminalScrollbackLines"
        static let optionAsMeta = "terminalOptionAsMeta"
        static let escapeKey = "terminalEscapeKey"
        static let announcesOutput = "terminalAnnouncesOutput"
        static let fontSize = "terminalFontSize"
        static let keyboardLetters = "keyboardLetters"
        static let keyboardHaptics = "keyboardHaptics"
        static let swipeKeySpeed = "keyboardSwipeKeySpeed"
        static let showsExtraKeysRowWithHardwareKeyboard = "keyboardShowsExtraKeysRowWithHardwareKeyboard"
    }

    /// The settings stored in `defaults`, or the defaults of `TerminalPreferences` for those never
    /// set. A stored value Settings would not offer is replaced by the default.
    public init(defaults: UserDefaults = .standard, cursorBlinks: Bool = true) {
        self.defaults = defaults
        self.cursorBlinks = cursorBlinks
        let standard = TerminalPreferences()
        let lines = defaults.object(forKey: Keys.scrollbackLines) as? Int
        scrollbackLines =
            lines.flatMap { TerminalPreferences.scrollbackChoices.contains($0) ? $0 : nil } ?? standard.scrollbackLines
        optionAsMeta = defaults.object(forKey: Keys.optionAsMeta) as? Bool ?? standard.optionAsMeta
        escapeKey = (defaults.string(forKey: Keys.escapeKey)).flatMap(EscapeKey.init) ?? standard.escapeKey
        announcesOutput = defaults.object(forKey: Keys.announcesOutput) as? Bool ?? standard.announcesOutput
        fontSize = TerminalPreferences.clampedFontSize(
            (defaults.object(forKey: Keys.fontSize) as? Double).map { CGFloat($0) } ?? standard.fontSize)
        keyboardLetters = defaults.string(forKey: Keys.keyboardLetters).flatMap(LettersLayout.ID.init)
        keyboardHaptics = defaults.object(forKey: Keys.keyboardHaptics) as? Bool ?? standard.keyboard.haptics
        swipeKeySpeed = KeyboardPreferences.clampedSwipeSpeed(
            defaults.object(forKey: Keys.swipeKeySpeed) as? Double ?? standard.keyboard.swipeSpeed)
        showsExtraKeysRowWithHardwareKeyboard =
            defaults.object(forKey: Keys.showsExtraKeysRowWithHardwareKeyboard) as? Bool
            ?? standard.keyboard.showsExtraKeysRowWithHardwareKeyboard
    }

    /// The settings as a terminal takes them.
    public var preferences: TerminalPreferences {
        TerminalPreferences(
            scrollbackLines: scrollbackLines, optionAsMeta: optionAsMeta, escapeKey: escapeKey,
            announcesOutput: announcesOutput, fontSize: fontSize,
            keyboard: KeyboardPreferences(
                letters: keyboardLetters, haptics: keyboardHaptics, swipeSpeed: swipeKeySpeed,
                showsExtraKeysRowWithHardwareKeyboard: showsExtraKeysRowWithHardwareKeyboard),
            cursorBlinks: cursorBlinks)
    }
}

extension EscapeKey {
    /// The key as Settings offers it.
    var displayName: String {
        switch self {
        case .none: "None"
        case .commandPeriod: "Command-Period"
        case .graveAccent: "Grave Accent (`)"
        }
    }
}
