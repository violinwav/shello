import Testing
import UIKit

@testable import ShelloTerminalUI

@Suite struct PreferencesTests {
    @Test func defaultsFollowTheSpec() {
        let preferences = TerminalPreferences()
        // README section 5: 10,000 lines of scrollback, Option as Meta, and the design's 13 points.
        #expect(preferences.scrollbackLines == 10_000)
        #expect(preferences.optionAsMeta)
        #expect(preferences.escapeKey == .none)
        #expect(preferences.announcesOutput)
        #expect(preferences.fontSize == 13)
    }

    /// The font size changes in whole points within its range, however it is set.
    @Test func fontSizeIsClampedToWholePoints() {
        var preferences = TerminalPreferences(fontSize: 13.4)
        #expect(preferences.fontSize == 13)
        preferences.fontSize = 100
        #expect(preferences.fontSize == 32)
        preferences.fontSize = 2
        #expect(preferences.fontSize == 8)
        preferences.fontSize = .nan
        #expect(preferences.fontSize == 13)
    }

    @Test func commandPeriodSendsEscapeOnlyWithCommandAlone() {
        let key = EscapeKey.commandPeriod
        #expect(key.sendsEscape(keyCode: .keyboardPeriod, modifiers: .command))
        // Caps Lock's state is not a key the user holds.
        #expect(key.sendsEscape(keyCode: .keyboardPeriod, modifiers: [.command, .alphaShift]))
        #expect(!key.sendsEscape(keyCode: .keyboardPeriod, modifiers: []))
        #expect(!key.sendsEscape(keyCode: .keyboardPeriod, modifiers: [.command, .shift]))
        #expect(!key.sendsEscape(keyCode: .keyboardComma, modifiers: .command))
    }

    /// The key left of 1 sends Esc on its own; with Shift it still types its other character.
    @Test func graveAccentKeySendsEscapeWithoutModifiers() {
        let key = EscapeKey.graveAccent
        #expect(key.sendsEscape(keyCode: .keyboardGraveAccentAndTilde, modifiers: []))
        #expect(!key.sendsEscape(keyCode: .keyboardGraveAccentAndTilde, modifiers: .shift))
        #expect(!key.sendsEscape(keyCode: .keyboardGraveAccentAndTilde, modifiers: .alternate))
    }

    @Test func noEscapeKeyLeavesEveryKeyAlone() {
        #expect(!EscapeKey.none.sendsEscape(keyCode: .keyboardGraveAccentAndTilde, modifiers: []))
        #expect(!EscapeKey.none.sendsEscape(keyCode: .keyboardPeriod, modifiers: .command))
    }

    @Test func nightThemeHasSixteenColorsAndTheDesignsBackground() {
        let theme = TerminalTheme.night
        #expect(theme.ansi.count == 16)
        #expect(theme.background == TerminalTheme.RGB(0x0A0B0D))
        #expect(theme.accent == TerminalTheme.RGB(0x0ABAB5))
    }

    /// A family that is not registered falls back to the system's monospaced font, with every
    /// face at the size asked for.
    @Test func typefaceFallsBackToTheSystemFont() {
        let fonts = TerminalTypeface(regular: "No-Such-Font", bold: "No-Such-Font-Bold").fonts(size: 15)
        #expect(fonts.regular.pointSize == 15)
        #expect(fonts.bold.pointSize == 15)
        #expect(fonts.italic.pointSize == 15)
        #expect(fonts.regular.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }
}
