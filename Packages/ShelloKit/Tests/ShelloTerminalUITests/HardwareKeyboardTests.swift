import GameController
import Testing
import UIKit

@testable import ShelloTerminalUI

/// Where a terminal learns whether a hardware keyboard is attached: GameController's reports, and the
/// stand-in tests attach and detach.
@MainActor
@Suite struct HardwareKeyboardMonitorTests {
    /// GameController merges the keyboards into one, so it reports the first connection and the last
    /// disconnection: a keyboard is attached in between.
    @Test func gameControllerMonitorFollowsTheConnections() async {
        let center = NotificationCenter()
        let monitor = GameControllerKeyboardMonitor(center: center, isAttached: false)
        var heard: [Bool] = []
        let observation = monitor.observe { heard.append($0) }
        center.post(name: .GCKeyboardDidConnect, object: nil)
        #expect(await eventually { monitor.isAttached })
        center.post(name: .GCKeyboardDidDisconnect, object: nil)
        #expect(await eventually { !monitor.isAttached })
        #expect(heard == [true, false])
        withExtendedLifetime(observation) {}
    }

    /// A monitor made while a keyboard is attached says so at once.
    @Test func gameControllerMonitorStartsAsTheKeyboardsAre() {
        #expect(GameControllerKeyboardMonitor(center: NotificationCenter(), isAttached: true).isAttached)
        #expect(!GameControllerKeyboardMonitor(center: NotificationCenter(), isAttached: false).isAttached)
    }

    /// Observers hear each change once, and nothing after their observation went.
    @Test func standInTellsItsObserversUntilTheyGo() {
        let standIn = HardwareKeyboardStandIn()
        var heard: [Bool] = []
        var observation: HardwareKeyboardObservation? = standIn.observe { heard.append($0) }
        standIn.isAttached = true
        standIn.isAttached = true
        standIn.isAttached = false
        #expect(heard == [true, false])
        withExtendedLifetime(observation) {}
        observation = nil
        standIn.isAttached = true
        #expect(heard == [true, false])
    }

    /// Waits up to five seconds for `condition`: NotificationCenter hands the main queue its
    /// notifications.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// A hardware keyboard hides the Shello keyboard (README section 6): what the terminal shows under it
/// as a hardware keyboard comes and goes.
@MainActor
@Suite struct HardwareKeyboardTests {
    let hardwareKeyboard = HardwareKeyboardStandIn()
    let fixture: TerminalFixture

    init() {
        fixture = TerminalFixture(hardwareKeyboard: hardwareKeyboard)
    }

    var keyboard: ShelloKeyboard { fixture.view.keyboard }

    /// What the terminal shows under it, as its input views say.
    enum Shown: Equatable {
        /// The Shello keyboard, under the extra keys row.
        case shelloKeyboard
        /// The extra keys row, over the system keyboard's place: iOS shows no system keyboard there
        /// while a hardware keyboard is attached.
        case extraKeysRow
        /// Neither keyboard nor row.
        case nothing
        case somethingElse
    }

    var shown: Shown {
        switch (fixture.view.inputView, fixture.view.inputAccessoryView) {
        case (let input?, let row?) where input === keyboard.keyboardView && row === keyboard.extraKeysRow:
            .shelloKeyboard
        case (nil, let row?) where row === keyboard.extraKeysRow: .extraKeysRow
        case (nil, nil): .nothing
        default: .somethingElse
        }
    }

    @Test func attachedKeyboardLeavesTheExtraKeysRowAlone() {
        #expect(shown == .shelloKeyboard)
        hardwareKeyboard.isAttached = true
        #expect(shown == .extraKeysRow)
        hardwareKeyboard.isAttached = false
        #expect(shown == .shelloKeyboard)
    }

    /// With the setting off, the row goes too while a hardware keyboard is attached; without one, the
    /// setting changes nothing.
    @Test func settingLeavesTheRowOutToo() {
        setShowsExtraKeysRow(false)
        #expect(shown == .shelloKeyboard)
        hardwareKeyboard.isAttached = true
        #expect(shown == .nothing)
        setShowsExtraKeysRow(true)
        #expect(shown == .extraKeysRow)
        setShowsExtraKeysRow(false)
        #expect(shown == .nothing)
        hardwareKeyboard.isAttached = false
        #expect(shown == .shelloKeyboard)
    }

    /// A terminal made while a hardware keyboard is attached starts without the Shello keyboard.
    @Test func terminalMadeWithAKeyboardAttachedStartsWithoutTheShelloKeyboard() {
        var preferences = TerminalPreferences()
        preferences.keyboard.showsExtraKeysRowWithHardwareKeyboard = false
        let attached = HardwareKeyboardStandIn(isAttached: true)
        let terminal = TerminalFixture(preferences: preferences, hardwareKeyboard: attached)
        #expect(terminal.view.inputView == nil)
        #expect(terminal.view.inputAccessoryView == nil)
        attached.isAttached = false
        #expect(terminal.view.inputView === terminal.view.keyboard.keyboardView)
        #expect(terminal.view.inputAccessoryView === terminal.view.keyboard.extraKeysRow)
    }

    /// The row's switch key shows the Shello keyboard anyway, for a hardware keyboard left attached in a
    /// bag, and hides it again; it says which it does. The next attachment hides it again.
    @Test func switchKeyShowsTheShelloKeyboardAnyway() {
        hardwareKeyboard.isAttached = true
        #expect(switchKeyName == "Show Shello Keyboard")
        pressSwitchKey()
        #expect(shown == .shelloKeyboard)
        #expect(switchKeyName == "Hide Shello Keyboard")
        pressSwitchKey()
        #expect(shown == .extraKeysRow)
        pressSwitchKey()
        hardwareKeyboard.isAttached = false
        #expect(shown == .shelloKeyboard)
        #expect(switchKeyName == "Switch to System Keyboard")
        hardwareKeyboard.isAttached = true
        #expect(shown == .extraKeysRow)
    }

    /// Showing the Shello keyboard anyway is for one terminal: another one, a tab of its own, keeps it
    /// hidden.
    @Test func switchKeyShowsTheShelloKeyboardForItsTerminalOnly() {
        let other = TerminalFixture(hardwareKeyboard: hardwareKeyboard)
        hardwareKeyboard.isAttached = true
        pressSwitchKey()
        #expect(shown == .shelloKeyboard)
        #expect(other.view.inputView == nil)
        #expect(other.view.inputAccessoryView === other.view.keyboard.extraKeysRow)
    }

    /// The Shello keyboard comes back in the layer it was in, and the keyboard the user had chosen
    /// comes back: the system keyboard, if they had switched to it.
    @Test func detachingBringsBackTheKeyboardAsItWas() {
        keyboard.show(.symbols)
        hardwareKeyboard.isAttached = true
        hardwareKeyboard.isAttached = false
        #expect(shown == .shelloKeyboard)
        #expect(keyboard.layer.kind == .symbols)
        pressSwitchKey()
        #expect(fixture.view.inputView == nil)
        hardwareKeyboard.isAttached = true
        hardwareKeyboard.isAttached = false
        #expect(fixture.view.inputView == nil)
        #expect(switchKeyName == "Switch to Shello Keyboard")
    }

    /// VoiceOver's focus never stays on keys that went away: from a key of the Shello keyboard it
    /// goes to the switch key, whose new name says that the keyboard hid, or to the terminal when the
    /// row went too, which VoiceOver then hears.
    @Test func voiceOverLeavesKeysThatGo() throws {
        let feedback = try typingWithVoiceOver()
        feedback.focusedElement = try keyOfTheShelloKeyboard()
        hardwareKeyboard.isAttached = true
        #expect(feedback.layoutChanges.count == 1)
        #expect(lastMove(feedback) === switchKey)
        #expect(feedback.announcements.isEmpty)

        hardwareKeyboard.isAttached = false
        setShowsExtraKeysRow(false)
        feedback.focusedElement = try keyOfTheShelloKeyboard()
        hardwareKeyboard.isAttached = true
        #expect(lastMove(feedback) === fixture.view)
        #expect(feedback.announcements.last == "On-screen keyboard and extra keys hidden")
        #expect(fixture.view.isFirstResponder)
    }

    /// VoiceOver stays where the user put it when nothing went from under it, on the terminal, a key
    /// of the row that stays, or anything else on screen, and hears what changed.
    @Test func voiceOverStaysWhereNothingWent() throws {
        let feedback = try typingWithVoiceOver()
        feedback.focusedElement = fixture.view
        hardwareKeyboard.isAttached = true
        #expect(feedback.layoutChanges.count == 1)
        #expect(lastMove(feedback) == nil)
        #expect(feedback.announcements == ["On-screen keyboard hidden"])

        feedback.focusedElement = NSObject()
        hardwareKeyboard.isAttached = false
        #expect(lastMove(feedback) == nil)
        #expect(feedback.announcements.last == "Shello keyboard shown")

        let row = keyboard.extraKeysRow
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 50)
        row.layoutIfNeeded()
        let escape = try #require(row.keyElements.first { $0.accessibilityLabel == "Escape" })
        feedback.focusedElement = escape
        hardwareKeyboard.isAttached = true
        #expect(lastMove(feedback) == nil)
        #expect(feedback.announcements.last == "On-screen keyboard hidden")
    }

    /// On the switch key, VoiceOver stays there and hears its new name, which says what changed: the
    /// key's own press, or a hardware keyboard that hid the Shello keyboard. A Shello keyboard that
    /// comes back, which its name does not say, is announced.
    @Test func voiceOverOnTheSwitchKeyHearsItsNewName() throws {
        let feedback = try typingWithVoiceOver()
        feedback.focusedElement = switchKey
        hardwareKeyboard.isAttached = true
        #expect(lastMove(feedback) === switchKey)
        pressSwitchKey()
        #expect(lastMove(feedback) === switchKey)
        pressSwitchKey()
        #expect(feedback.layoutChanges.count == 3)
        #expect(feedback.announcements.isEmpty)
        hardwareKeyboard.isAttached = false
        #expect(lastMove(feedback) === switchKey)
        #expect(feedback.announcements == ["Shello keyboard shown"])
    }

    /// Control and Alt let go with the row, which VoiceOver hears: their keys, which said so, went.
    @Test func voiceOverHearsTheModifiersLetGo() throws {
        let feedback = try typingWithVoiceOver()
        feedback.focusedElement = fixture.view
        keyboard.setLocked(.control, true)
        feedback.announcements = []
        setShowsExtraKeysRow(false)
        hardwareKeyboard.isAttached = true
        #expect(feedback.announcements == ["On-screen keyboard and extra keys hidden. Control off"])
    }

    /// Only the terminal that has the keyboard focus moves VoiceOver or speaks: the others' keys are
    /// not on screen.
    @Test func terminalWithoutTheKeyboardFocusLeavesVoiceOverAlone() throws {
        let feedback = try typingWithVoiceOver()
        feedback.focusedElement = try keyOfTheShelloKeyboard()
        _ = fixture.view.resignFirstResponder()
        hardwareKeyboard.isAttached = true
        #expect(feedback.layoutChanges.isEmpty)
        #expect(feedback.announcements.isEmpty)
    }

    /// While a hardware keyboard is attached, the terminal's actions show and hide the Shello keyboard
    /// too: with the row turned off, they are the one way to it, for VoiceOver, Switch Control and Full
    /// Keyboard Access.
    @Test func terminalActionsShowTheShelloKeyboard() throws {
        #expect(!actionNames.contains("Show Shello Keyboard"))
        setShowsExtraKeysRow(false)
        hardwareKeyboard.isAttached = true
        let show = try #require(fixture.view.accessibilityCustomActions?.first { $0.name == "Show Shello Keyboard" })
        _ = show.actionHandler?(show)
        #expect(shown == .shelloKeyboard)
        #expect(actionNames.contains("Hide Shello Keyboard"))
        hardwareKeyboard.isAttached = false
        #expect(!actionNames.contains { $0.hasSuffix("Shello Keyboard") })
        #expect(actionNames.contains("Read Current Line"))
    }

    /// Voice Control knows the switch key by what it does while a hardware keyboard is attached, as
    /// the system's own key to hide the keyboard is known, and always as Switch Keyboard.
    @Test func voiceControlKnowsTheSwitchKeyByWhatItDoes() {
        hardwareKeyboard.isAttached = true
        #expect(
            keyboard.userInputLabels(for: keyboard.switchKey)
                == ["Show Shello Keyboard", "Switch Keyboard", "Show Keyboard"])
        pressSwitchKey()
        #expect(
            keyboard.userInputLabels(for: keyboard.switchKey)
                == ["Hide Shello Keyboard", "Switch Keyboard", "Hide Keyboard"])
    }

    /// The switch key, as VoiceOver finds it.
    private var switchKey: KeyAccessibilityElement { keyboard.extraKeysRow.switchAccessibilityElement }

    private var actionNames: [String] { fixture.view.accessibilityCustomActions?.map(\.name) ?? [] }

    /// The terminal in the key window, with the keyboard focus, and VoiceOver running.
    private func typingWithVoiceOver() throws -> RecordedKeyboardFeedback {
        let feedback = RecordedKeyboardFeedback()
        feedback.isVoiceOverRunning = true
        keyboard.feedback = feedback.feedback
        fixture.window.makeKeyAndVisible()
        try #require(fixture.view.becomeFirstResponder())
        return feedback
    }

    /// A key of the Shello keyboard, as VoiceOver finds it.
    private func keyOfTheShelloKeyboard() throws -> KeyAccessibilityElement {
        let view = keyboard.keyboardView
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
        view.layoutIfNeeded()
        return try #require((view.accessibilityElements as? [KeyAccessibilityElement])?.first)
    }

    /// Where the last layout change took VoiceOver: an element, or nil where it stayed.
    private func lastMove(_ feedback: RecordedKeyboardFeedback) -> AnyObject? {
        feedback.layoutChanges.last ?? nil
    }

    /// While the Shello keyboard hides, a hardware keyboard's text reaches the terminal, and Control
    /// armed on the row applies to it. Without the row, Control and Alt let go: nothing would show
    /// them, nor turn a locked one off.
    @Test func hardwareKeyboardTypesWithTheRowsModifiers() throws {
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        hardwareKeyboard.isAttached = true
        fixture.view.insertText("l")
        keyboard.press(try #require(ExtraKeys.standard.first { $0.action == .modifier(.control) }))
        fixture.view.insertText("c")
        #expect(stream.sent == [UInt8(ascii: "l"), 0x03])
        keyboard.setLocked(.control, true)
        keyboard.setLocked(.alt, true)
        setShowsExtraKeysRow(false)
        #expect(fixture.controller.modifiers == ArmedModifiers())
        fixture.view.insertText("c")
        #expect(stream.sent == [UInt8(ascii: "l"), 0x03, UInt8(ascii: "c")])
    }

    /// Alone at the bottom of the screen, the row keeps a margin under its keys, as the keyboard does
    /// that it otherwise sits on: here, in a window without a home indicator, as much as above them.
    @Test func rowAloneKeepsAMarginUnderItsKeys() {
        let row = keyboard.extraKeysRow
        let onKeyboard = row.intrinsicContentSize.height
        hardwareKeyboard.isAttached = true
        #expect(row.intrinsicContentSize.height == onKeyboard + row.metrics.insets.top)
        pressSwitchKey()
        #expect(row.intrinsicContentSize.height == onKeyboard)
    }

    /// The name VoiceOver and Voice Control know the switch key by, as the row has it now.
    private var switchKeyName: String? {
        let row = keyboard.extraKeysRow
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 50)
        row.layoutIfNeeded()
        return row.switchAccessibilityElement.accessibilityLabel
    }

    /// Presses the switch key as VoiceOver does, which is what a tap on it does too.
    private func pressSwitchKey() {
        _ = keyboard.extraKeysRow.switchAccessibilityElement.accessibilityActivate()
    }

    private func setShowsExtraKeysRow(_ shows: Bool) {
        var preferences = fixture.controller.preferences
        preferences.keyboard.showsExtraKeysRowWithHardwareKeyboard = shows
        fixture.controller.preferences = preferences
    }
}
