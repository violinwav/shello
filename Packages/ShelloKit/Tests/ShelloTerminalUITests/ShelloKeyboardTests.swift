import Testing
import UIKit

@testable import ShelloTerminalUI

/// The Shello keyboard on a terminal (README section 6): what its keys send to the stream, sticky
/// Control and Alt on both keyboards, the switch to the system keyboard, the swipe key, VoiceOver,
/// haptics and the settings.
@MainActor
@Suite(.serialized) struct ShelloKeyboardTests {
    let fixture = TerminalFixture()
    let stream = RecordingStream()
    let feedback = RecordedKeyboardFeedback()

    init() {
        fixture.controller.attach(stream)
        keyboard.feedback = feedback.feedback
    }

    var keyboard: ShelloKeyboard { fixture.view.keyboard }

    /// The key labelled `label` on the layer that shows, or on the extra keys row.
    func key(_ label: String) -> KeyboardKey {
        let keys = keyboard.layer.keys + ExtraKeys.standard
        guard let key = keys.first(where: { $0.label == label }) else {
            Issue.record("No key \(label)")
            return .space
        }
        return key
    }

    func press(_ labels: String...) {
        for label in labels {
            keyboard.press(key(label))
        }
    }

    @Test func keyboardIsTheInputViewAndTheRowItsAccessory() {
        #expect(fixture.view.inputView === keyboard.keyboardView)
        #expect(fixture.view.inputAccessoryView === keyboard.extraKeysRow)
        keyboard.press(ExtraKeys.switchKey(.toSystemKeyboard))
        #expect(keyboard.usesSystemKeyboard)
        #expect(fixture.view.inputView == nil)
        // The row stays above the system keyboard, with the key that brings the Shello keyboard back.
        #expect(fixture.view.inputAccessoryView === keyboard.extraKeysRow)
        #expect(keyboard.spokenLabel(for: keyboard.switchKey) == "Switch to Shello Keyboard")
        keyboard.press(ExtraKeys.switchKey(.toShelloKeyboard))
        #expect(fixture.view.inputView === keyboard.keyboardView)
    }

    @Test func lettersShiftAndCapsLock() {
        press("l", "s", "space")
        #expect(stream.sentText == "ls ")
        // Shift for one letter.
        press("⇧", "a", "b")
        #expect(stream.sentText.hasSuffix("Ab"))
        // A double tap is Caps Lock, until Shift is tapped again.
        keyboard.press(key("⇧"), at: 10)
        keyboard.press(key("⇧"), at: 10.1)
        #expect(keyboard.displayLabel(for: key("⇧")) == "⇪")
        press("c", "d")
        #expect(stream.sentText.hasSuffix("CD"))
        keyboard.press(key("⇧"), at: 20)
        press("e")
        #expect(stream.sentText.hasSuffix("CDe"))
    }

    @Test func flickAndAlternatesTypeTheirText() {
        keyboard.press(key("q"), text: "1")
        keyboard.press(key("e"), text: "é")
        // With Shift, an alternate is a capital too.
        press("⇧")
        keyboard.press(key("e"), text: "é")
        #expect(stream.sentText == "1éÉ")
    }

    @Test func controlArmedOnTheRowAppliesToTheNextKeyOnly() {
        press("ctrl", "c", "c")
        #expect(stream.sent == [0x03, UInt8(ascii: "c")])
        #expect(fixture.controller.modifiers == ArmedModifiers())
    }

    @Test func doubleTapLocksControlForEveryKey() {
        keyboard.press(key("ctrl"), at: 10)
        keyboard.press(key("ctrl"), at: 10.2)
        #expect(fixture.controller.modifiers.control == .locked)
        press("a", "e")
        #expect(stream.sent == [0x01, 0x05])
        keyboard.press(key("ctrl"), at: 20)
        press("a")
        #expect(stream.sent == [0x01, 0x05, UInt8(ascii: "a")])
    }

    @Test func altSendsEscapeFirst() {
        press("alt", "b", "alt", "ctrl", "c")
        #expect(stream.sent == [0x1B, UInt8(ascii: "b"), 0x1B, 0x03])
    }

    /// Sticky modifiers work with the system keyboard too (README section 6): its text goes
    /// through the terminal's `insertText`, and its Delete through `deleteBackward`.
    @Test func modifiersApplyToTheSystemKeyboard() {
        keyboard.press(ExtraKeys.switchKey(.toSystemKeyboard))
        press("ctrl")
        fixture.view.insertText("c")
        fixture.view.insertText("x")
        #expect(stream.sent == [0x03, UInt8(ascii: "x")])
        press("alt")
        fixture.view.insertText("f")
        press("alt")
        fixture.view.deleteBackward()
        press("ctrl", "alt")
        fixture.view.insertText("\n")
        #expect(
            Array(stream.sent.dropFirst(2)) == [0x1B, UInt8(ascii: "f"), 0x1B, 0x7F, 0x1B, 0x0D])
        #expect(fixture.controller.modifiers == ArmedModifiers())
    }

    /// Dictation and other text of more words is not a key: it goes as it is, and the modifier
    /// waits for a key.
    @Test func textOfMoreCharactersIgnoresTheModifiers() {
        press("ctrl")
        fixture.view.insertText("make")
        #expect(stream.sentText == "make")
        #expect(fixture.controller.modifiers.control == .armed)
    }

    /// The arrows follow the program's cursor key mode, as SwiftTerm's own keys do.
    @Test func swipeKeyArrowsFollowTheCursorKeyMode() {
        keyboard.handle(.arrow(.right, time: CACurrentMediaTime()))
        keyboard.handle(.arrow(.up, time: CACurrentMediaTime()))
        #expect(stream.sentText == "\u{1B}[C\u{1B}[A")
        fixture.feed("\u{1B}[?1h")
        keyboard.handle(.arrow(.left, time: CACurrentMediaTime()))
        #expect(stream.sentText.hasSuffix("\u{1B}OD"))
        // With Control: a word at a time, in either mode, for the whole drag.
        press("ctrl")
        keyboard.handle(.arrow(.right, time: CACurrentMediaTime()))
        keyboard.handle(.arrow(.right, time: CACurrentMediaTime()))
        #expect(stream.sentText.hasSuffix("\u{1B}[1;5C\u{1B}[1;5C"))
        keyboard.handle(.swipeEnded)
        #expect(fixture.controller.modifiers == ArmedModifiers())
    }

    @Test func functionLayerKeys() {
        keyboard.show(.function)
        press("F1", "F5", "F12", "del", "ins", "home", "end", "^C", "^W")
        #expect(
            stream.sentText
                == "\u{1B}OP\u{1B}[15~\u{1B}[24~\u{1B}[3~\u{1B}[2~\u{1B}[H\u{1B}[F\u{3}\u{17}")
        press("alt", "F5")
        #expect(stream.sentText.hasSuffix("\u{1B}[15;3~"))
        press("←", "↑", "↓", "→")
        #expect(stream.sentText.hasSuffix("\u{1B}[D\u{1B}[A\u{1B}[B\u{1B}[C"))
    }

    /// PgUp and PgDn page through a full-screen program, and through the scrollback of a shell, as
    /// on a hardware keyboard.
    @Test func pageKeysGoToFullScreenPrograms() {
        keyboard.show(.function)
        press("pgup")
        #expect(stream.sent.isEmpty)
        fixture.feed("\u{1B}[?1049h")
        press("pgup", "pgdn")
        #expect(stream.sentText == "\u{1B}[5~\u{1B}[6~")
    }

    @Test func extraKeysSendEscapeTabAndSymbols() {
        press("esc", "tab", "|", "~", "/", "-", "$", ">", "*")
        #expect(stream.sentText == "\u{1B}\t|~/-$>*")
    }

    /// VoiceOver can type: every key is a keyboard key with a name, and activating it presses it.
    @Test func everyKeyIsAKeyboardKeyThatVoiceOverCanPress() {
        let view = keyboard.keyboardView
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
        view.layoutIfNeeded()
        let elements = view.accessibilityElements as? [KeyAccessibilityElement] ?? []
        #expect(elements.count == keyboard.layer.keys.count)
        for element in elements {
            #expect(element.accessibilityTraits.contains(.keyboardKey))
            #expect(!(element.accessibilityLabel ?? "").isEmpty)
        }
        // Typing "hi" and Return with VoiceOver's double taps.
        for label in ["h", "i", "Return"] {
            _ = elements.first { $0.accessibilityLabel == label }?.accessibilityActivate()
        }
        #expect(stream.sentText == "hi\r")
        // The corner symbol and the alternates are actions of their key.
        let e = elements.first { $0.accessibilityLabel == "e" }
        #expect(e?.accessibilityCustomActions?.map(\.name).prefix(3) == ["3", "è", "é"])
    }

    @Test func swipeKeyLetsVoiceOverDragAndOffersEachArrow() {
        let row = keyboard.extraKeysRow
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 50)
        row.layoutIfNeeded()
        let elements = row.keyElements
        #expect(elements.count == ExtraKeys.standard.count + 1)
        #expect(elements.allSatisfy { $0.accessibilityTraits.contains(.keyboardKey) })
        #expect(elements.last?.accessibilityLabel == "Switch to System Keyboard")
        let swipe = elements.first { $0.accessibilityLabel == "Swipe Key" }
        #expect(swipe?.accessibilityTraits.contains(.allowsDirectInteraction) == true)
        #expect(swipe?.accessibilityTraits.contains(.keyboardKey) == true)
        let actions = swipe?.accessibilityCustomActions ?? []
        #expect(actions.map(\.name) == ["Up Arrow", "Down Arrow", "Left Arrow", "Right Arrow"])
        _ = actions.last?.actionHandler?(actions.last!)
        #expect(stream.sentText == "\u{1B}[C")
        let control = elements.first { $0.accessibilityLabel == "Control" }
        press("ctrl")
        #expect(control?.accessibilityValue == "Armed")
    }

    /// With VoiceOver, a modifier says its new state, which only its key shows.
    @Test func voiceOverHearsTheModifiersState() {
        feedback.isVoiceOverRunning = true
        keyboard.press(key("ctrl"), at: 10)
        keyboard.press(key("ctrl"), at: 10.1)
        keyboard.press(key("ctrl"), at: 20)
        #expect(feedback.announcements == ["Control, Armed", "Control, Locked", "Control, Off"])
    }

    /// VoiceOver and Switch Control lock a modifier with one action, since their double tap is
    /// too slow for a double tap on the key, and unlock it the same way.
    @Test func modifiersLockAndUnlockWithAnAction() throws {
        feedback.isVoiceOverRunning = true
        let row = keyboard.extraKeysRow
        row.frame = CGRect(x: 0, y: 0, width: 390, height: 50)
        row.layoutIfNeeded()
        let control = try #require(row.keyElements.first { $0.accessibilityLabel == "Control" })
        let lock = try #require(control.accessibilityCustomActions?.first { $0.name == "Lock" })
        _ = lock.actionHandler?(lock)
        #expect(fixture.controller.modifiers.control == .locked)
        #expect(control.accessibilityValue == "Locked")
        press("a", "e")
        #expect(stream.sent == [0x01, 0x05])
        let unlock = try #require(control.accessibilityCustomActions?.first { $0.name == "Unlock" })
        _ = unlock.actionHandler?(unlock)
        #expect(fixture.controller.modifiers.control == .off)
        #expect(feedback.announcements == ["Control, Locked", "Control, Off"])
        // Shift's lock is Caps Lock.
        let view = keyboard.keyboardView
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
        view.layoutIfNeeded()
        let elements = view.accessibilityElements as? [KeyAccessibilityElement] ?? []
        let shift = try #require(elements.first { $0.accessibilityLabel == "Shift" })
        let lockShift = try #require(shift.accessibilityCustomActions?.first { $0.name == "Lock" })
        _ = lockShift.actionHandler?(lockShift)
        #expect(shift.accessibilityValue == "Caps Lock")
        // Held on its own, a modifier locks too; held for a key, even on the other keyboard, not.
        press("alt")
        keyboard.handle(.lock(key("alt"), time: CACurrentMediaTime()))
        #expect(fixture.controller.modifiers.alt == .locked)
        press("ctrl", "c")
        keyboard.handle(.lock(key("ctrl"), time: CACurrentMediaTime()))
        #expect(fixture.controller.modifiers.control == .off)
        // A long press on a locked modifier turns it off, as a tap does, and leaves it off.
        press("alt")
        keyboard.handle(.lock(key("alt"), time: CACurrentMediaTime()))
        #expect(fixture.controller.modifiers.alt == .off)
    }

    /// After a layer change, VoiceOver hears which layer shows.
    @Test func voiceOverHearsTheNewLayer() {
        feedback.isVoiceOverRunning = true
        press("123")
        #expect(feedback.announcements == ["Symbols"])
        press("abc")
        #expect(feedback.announcements == ["Symbols", "Letters"])
    }

    /// The keys keep their elements as the layer changes, and the element now where the pressed
    /// layer key was, which VoiceOver moves to, names the key there.
    @Test func layerChangeKeepsTheElements() throws {
        let view = keyboard.keyboardView
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
        view.layoutIfNeeded()
        let before = view.accessibilityElements as? [KeyAccessibilityElement] ?? []
        let symbols = try #require(before.first { $0.accessibilityLabel == "Symbols" })
        let place = symbols.accessibilityFrameInContainerSpace
        _ = symbols.accessibilityActivate()
        #expect(keyboard.layer.kind == .symbols)
        let after = view.accessibilityElements as? [KeyAccessibilityElement] ?? []
        #expect(after.count == keyboard.layer.keys.count)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
        let there = after.first {
            $0.accessibilityFrameInContainerSpace.contains(CGPoint(x: place.midX, y: place.midY))
        }
        #expect(there?.accessibilityLabel == "Letters")
        _ = there?.accessibilityActivate()
        #expect(keyboard.layer.kind == .letters)
    }

    /// Activating the swipe key sends nothing, so it neither taps nor clicks. A touch on its dot
    /// sends nothing either, and leaves Control armed; a tap on an arrow sends it with Control.
    @Test func swipeKeySendsOnlyWhatItIsTouchedFor() {
        let swipe = ExtraKeys.standard.first { $0.action == .arrows }!
        press("ctrl")
        keyboard.press(swipe)
        #expect(stream.sent.isEmpty)
        #expect(feedback.haptics == 1)
        keyboard.handle(.touchDown(swipe))
        keyboard.handle(.swipeEnded)
        #expect(fixture.controller.modifiers.control == .armed)
        keyboard.handle(.touchDown(swipe))
        keyboard.handle(.arrow(.left, time: CACurrentMediaTime()))
        keyboard.handle(.swipeEnded)
        #expect(stream.sentText == "\u{1B}[1;5D")
        #expect(fixture.controller.modifiers == ArmedModifiers())
    }

    /// Voice Control knows a key by what it shows too, such as "123", and some symbols by their
    /// other names.
    @Test func voiceControlKnowsKeysByWhatTheyShow() {
        #expect(keyboard.userInputLabels(for: KeyboardKey.layer(.symbols)) == ["Symbols", "123"])
        #expect(keyboard.userInputLabels(for: key("esc")) == ["Escape", "esc"])
        #expect(keyboard.userInputLabels(for: key("|")) == ["Vertical Bar", "Pipe"])
        #expect(keyboard.userInputLabels(for: key("q")) == ["q"])
        #expect(
            keyboard.userInputLabels(for: keyboard.switchKey) == ["Switch to System Keyboard", "Switch Keyboard"])
        let swipe = ExtraKeys.standard.first { $0.action == .arrows }!
        #expect(keyboard.userInputLabels(for: swipe) == ["Swipe Key", "Arrows"])
    }

    /// A pressed key keeps its text readable: on the lighter pressed key, corner symbols and the
    /// Control combinations take the label's colour.
    @Test func pressedKeysKeepTheirTextReadable() {
        let palette = keyboard.palette
        func face(_ label: String, isPressed: Bool) -> KeyFace {
            keyboard.face(
                for: key(label), frame: CGRect(x: 0, y: 0, width: 34, height: 44), isPressed: isPressed,
                metrics: metrics)
        }
        #expect(face("q", isPressed: false).cornerColor == palette.secondaryLabel)
        #expect(face("q", isPressed: true).cornerColor == palette.label)
        keyboard.show(.function)
        #expect(face("^C", isPressed: false).foreground == palette.accentLabel)
        #expect(face("^C", isPressed: true).foreground == palette.label)
    }

    /// Bold Text draws every label in the bold face, and Increase Contrast outlines every key.
    @Test func boldTextAndIncreasedContrast() {
        let frame = CGRect(x: 0, y: 0, width: 34, height: 44)
        let plain = keyboard.face(for: key("q"), frame: frame, isPressed: false, metrics: metrics)
        #expect(plain.ring == nil)
        let traits = UITraitCollection { traits in
            traits.legibilityWeight = .bold
            traits.accessibilityContrast = .high
        }
        let adapted = KeyboardMetrics.keyboard(for: traits)
        #expect(adapted.boldText)
        #expect(adapted.highContrast)
        let face = keyboard.face(for: key("q"), frame: frame, isPressed: false, metrics: adapted)
        #expect(face.labelFont.fontName == keyboard.typeface.font(size: 17, bold: true).fontName)
        #expect(face.labelFont.fontName != plain.labelFont.fontName)
        #expect(face.ring == keyboard.palette.secondaryLabel)
    }

    /// On a light keyboard an armed Control turns dark, as Shift does: the accent would hardly
    /// stand out from the light keys. The dark keyboard keeps the accent.
    @Test func lightKeyboardShowsArmedModifiersDark() {
        var paper = TerminalTheme.night
        paper.background = TerminalTheme.RGB(0xF7F6F2)
        paper.foreground = TerminalTheme.RGB(0x1E2125)
        let light = ShelloKeyboard(
            theme: paper, typeface: keyboard.typeface, preferences: KeyboardPreferences(letters: .qwerty))
        light.feedback = feedback.feedback
        let control = key("ctrl")
        let frame = CGRect(x: 0, y: 0, width: 48, height: 42)
        light.press(control)
        let face = light.face(for: control, frame: frame, isPressed: false, metrics: metrics)
        #expect(face.background == light.palette.activeKey)
        #expect(face.foreground == light.palette.onActiveKey)
        keyboard.press(control)
        #expect(
            keyboard.face(for: control, frame: frame, isPressed: false, metrics: metrics).background
                == keyboard.palette.accent)
    }

    /// The design's sizes on a phone.
    private var metrics: KeyboardMetrics {
        KeyboardMetrics(keyHeight: 44, keySpacing: 5, rowSpacing: 10, insets: .zero, cornerRadius: 7, labelScale: 1)
    }

    @Test func eachKeyTapsAndClicksOnceUnlessHapticsAreOff() {
        press("a", "ctrl", "b")
        #expect(feedback.haptics == 3)
        #expect(feedback.clicks == 3)
        keyboard.press(key("⌫"), isRepeat: true)
        #expect(feedback.haptics == 3)
        keyboard.preferences.haptics = false
        press("c")
        #expect(feedback.haptics == 3)
        #expect(feedback.clicks == 4)
    }

    /// The cursor stays steady when the settings say it does not blink, as in UI tests, whatever a
    /// program asks for, and blinks again when they allow it.
    @Test func cursorBlinksUnlessTheSettingsSayNot() {
        var preferences = fixture.controller.preferences
        preferences.cursorBlinks = false
        fixture.controller.preferences = preferences
        #expect(fixture.view.terminalStateSnapshot().cursorStyle == .steadyBlock)
        #expect(fixture.view.isCursorSteady)
        preferences.cursorBlinks = true
        fixture.controller.preferences = preferences
        #expect(fixture.view.terminalStateSnapshot().cursorStyle == .blinkBlock)
        #expect(!fixture.view.isCursorSteady)
    }

    @Test func settingsChooseTheLettersAndTheSwipeKeysSpeed() {
        var preferences = fixture.controller.preferences
        preferences.keyboard = KeyboardPreferences(letters: .qwertz, haptics: true, swipeSpeed: 2)
        fixture.controller.preferences = preferences
        #expect(keyboard.letters.id == .qwertz)
        #expect(keyboard.layer.rows[0].keys.map(\.label).joined() == "qwertzuiop")
        #expect(keyboard.extraKeysRow.touches.swipeSpeed == 2)
        preferences.keyboard.letters = .qwerty
        fixture.controller.preferences = preferences
        #expect(keyboard.layer.rows[0].keys.map(\.label).joined() == "qwertyuiop")
    }
}

/// What the keyboard gives back, recorded instead of felt and heard.
@MainActor
final class RecordedKeyboardFeedback {
    var prepared = 0
    var haptics = 0
    var clicks = 0
    var isVoiceOverRunning = false
    var announcements: [String] = []
    /// The element VoiceOver is on.
    var focusedElement: AnyObject?
    /// The layout changes posted as the keys on screen changed, each with where VoiceOver went: nil
    /// where it stayed.
    var layoutChanges: [AnyObject?] = []

    var feedback: KeyboardFeedback {
        KeyboardFeedback(
            prepare: { [unowned self] in self.prepared += 1 },
            haptic: { [unowned self] in self.haptics += 1 },
            click: { [unowned self] in self.clicks += 1 },
            isVoiceOverRunning: { [unowned self] in self.isVoiceOverRunning },
            announce: { [unowned self] in self.announcements.append($0) },
            voiceOverFocus: { [unowned self] in self.focusedElement },
            layoutChanged: { [unowned self] in self.layoutChanges.append($0) })
    }
}
