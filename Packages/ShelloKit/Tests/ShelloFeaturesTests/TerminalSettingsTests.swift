import ShelloTerminalUI
import Testing

@testable import ShelloFeatures

/// The terminal settings stay on the device, across launches (README section 5).
@MainActor
@Suite struct TerminalSettingsTests {
    let settings = TestDefaults()

    @Test func startsWithTheDefaults() {
        let terminal = TerminalSettings(defaults: settings.defaults)
        #expect(terminal.preferences == TerminalPreferences())
        // The extra keys row stays with a hardware keyboard (README section 6).
        #expect(terminal.showsExtraKeysRowWithHardwareKeyboard)
    }

    @Test func keepsWhatTheUserChose() {
        let terminal = TerminalSettings(defaults: settings.defaults)
        terminal.scrollbackLines = 20_000
        terminal.optionAsMeta = false
        terminal.escapeKey = .graveAccent
        terminal.announcesOutput = false
        terminal.fontSize = 17

        let relaunched = TerminalSettings(defaults: settings.defaults)
        #expect(
            relaunched.preferences
                == TerminalPreferences(
                    scrollbackLines: 20_000, optionAsMeta: false, escapeKey: .graveAccent, announcesOutput: false,
                    fontSize: 17))
    }

    /// The Shello keyboard's settings (README section 6) stay too; Automatic is no stored layout.
    @Test func keepsTheKeyboardSettings() {
        let terminal = TerminalSettings(defaults: settings.defaults)
        terminal.keyboardLetters = .qwertz
        terminal.keyboardHaptics = false
        terminal.swipeKeySpeed = 2.5
        terminal.showsExtraKeysRowWithHardwareKeyboard = false

        let relaunched = TerminalSettings(defaults: settings.defaults)
        #expect(
            relaunched.preferences.keyboard
                == KeyboardPreferences(
                    letters: .qwertz, haptics: false, swipeSpeed: 2.5, showsExtraKeysRowWithHardwareKeyboard: false))
        relaunched.keyboardLetters = nil
        #expect(TerminalSettings(defaults: settings.defaults).keyboardLetters == nil)
    }

    /// A stored value that Settings would not offer reads as the default.
    @Test func replacesValuesSettingsWouldNotOffer() {
        settings.defaults.set(123, forKey: "terminalScrollbackLines")
        settings.defaults.set("capsLock", forKey: "terminalEscapeKey")
        settings.defaults.set(400.0, forKey: "terminalFontSize")
        settings.defaults.set("dvorak", forKey: "keyboardLetters")
        settings.defaults.set(7.0, forKey: "keyboardSwipeKeySpeed")
        let terminal = TerminalSettings(defaults: settings.defaults)
        #expect(terminal.scrollbackLines == 10_000)
        #expect(terminal.escapeKey == .none)
        #expect(terminal.fontSize == TerminalPreferences.fontSizes.upperBound)
        #expect(terminal.keyboardLetters == nil)
        #expect(terminal.swipeKeySpeed == KeyboardPreferences.swipeSpeeds.upperBound)
    }

    @Test func namesEveryEscapeKey() {
        #expect(EscapeKey.allCases.map(\.displayName) == ["None", "Command-Period", "Grave Accent (`)"])
    }
}
