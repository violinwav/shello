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

    /// A stored value that Settings would not offer reads as the default.
    @Test func replacesValuesSettingsWouldNotOffer() {
        settings.defaults.set(123, forKey: "terminalScrollbackLines")
        settings.defaults.set("capsLock", forKey: "terminalEscapeKey")
        settings.defaults.set(400.0, forKey: "terminalFontSize")
        let terminal = TerminalSettings(defaults: settings.defaults)
        #expect(terminal.scrollbackLines == 10_000)
        #expect(terminal.escapeKey == .none)
        #expect(terminal.fontSize == TerminalPreferences.fontSizes.upperBound)
    }

    @Test func namesEveryEscapeKey() {
        #expect(EscapeKey.allCases.map(\.displayName) == ["None", "Command-Period", "Grave Accent (`)"])
    }
}
