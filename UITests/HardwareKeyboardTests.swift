import XCTest
import notify

/// A hardware keyboard hides the Shello keyboard (README section 6), on the terminal demo: its keys go
/// and the extra keys row stays, the hardware keyboard types on, the row's switch key shows the Shello
/// keyboard anyway, and detaching brings the keys back in the layer they were in; the setting takes
/// the row away too. The hardware keyboard is a stand-in that the tests attach and detach, never the
/// Simulator's own.
final class HardwareKeyboardTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHardwareKeyboardHidesTheShelloKeyboardButNotTheRow() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.openTerminalDemo()
        app.showShelloKeyboard()
        // The Shello keyboard, on its symbols layer.
        let keyboard = app.shelloKeyboard
        keyboard.keys["Symbols"].tap()
        XCTAssertTrue(keyboard.keys["1"].waitForExistence(timeout: 10))

        SimulatedHardwareKeyboard.attach()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10))
        let row = app.extraKeysRow
        let show = row.keys["Show Shello Keyboard"]
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        XCTAssertTrue(row.keys["Escape"].exists)
        try app.auditAccessibility()

        // The hardware keyboard types on in the terminal: Control-C, then help. The simulator drops
        // the first key from a hardware keyboard after the on-screen keyboard typed: Shift goes first.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        app.typeKey("c", modifierFlags: .control)
        app.typeText("help\n")

        // The switch key shows the Shello keyboard anyway, in its layer, and hides it again.
        show.tap()
        XCTAssertTrue(keyboard.keys["1"].waitForExistence(timeout: 10))
        row.keys["Hide Shello Keyboard"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10))

        // Detached, the keys come back in the layer they were in: the terminal kept the focus.
        SimulatedHardwareKeyboard.detach()
        XCTAssertTrue(keyboard.keys["1"].waitForExistence(timeout: 10))
        XCTAssertTrue(row.keys["Switch to System Keyboard"].exists)

        // Both keys reached the demo: help ran, after the new prompt Control-C gave.
        app.search(for: "fast as it")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.search(for: "demo$")
        XCTAssertTrue(app.staticTexts["2 of 3"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    /// Settings, Hardware Keyboard, Extra Keys Row takes the row away too: with a hardware keyboard
    /// attached, the terminal shows neither keys nor row, and detaching brings both back. The
    /// Hardware Keyboard screen, with Option as Meta and the extra Esc key as they start, is audited.
    @MainActor
    func testSettingTakesTheRowAwayToo() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(environment: SimulatedHardwareKeyboard.attachedAtLaunch)
        app.openSettings()
        let hardwareKeyboardSettings = app.buttons["Hardware Keyboard"]
        app.revealFarDown(hardwareKeyboardSettings)
        hardwareKeyboardSettings.tap()
        XCTAssertTrue(app.navigationBars["Hardware Keyboard"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["Option Key as Meta"].value as? String, "1")
        XCTAssertEqual(app.picker("Extra Esc Key").label, "Extra Esc Key, None")
        let row = app.switches["Extra Keys Row"]
        XCTAssertEqual(row.value as? String, "1")
        app.turnOff(row)
        try app.auditAccessibility()
        app.navigationBars["Hardware Keyboard"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        app.openTerminalDemoFromSettings()

        app.focusTerminal()
        XCTAssertFalse(app.shelloKeyboard.exists)
        XCTAssertFalse(app.extraKeysRow.exists)

        // The terminal kept the focus: detached, its keyboard and row come back.
        SimulatedHardwareKeyboard.detach()
        XCTAssertTrue(app.shelloKeyboard.keys["q"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.extraKeysRow.keys["Escape"].exists)
    }
}

/// The hardware keyboard the app takes for attached in UI tests (App/ShelloApp.swift): a stand-in,
/// attached at launch or later with Darwin notifications, which the test runner and the app share on
/// a simulator.
enum SimulatedHardwareKeyboard {
    /// The launch environment of an app that starts with the hardware keyboard attached.
    static let attachedAtLaunch = ["SHELLO_UI_TESTING_HARDWARE_KEYBOARD": "1"]

    static func attach() {
        notify_post("ch.shello.Shello.UITests.hardwareKeyboardAttached")
    }

    static func detach() {
        notify_post("ch.shello.Shello.UITests.hardwareKeyboardDetached")
    }
}

extension XCUIApplication {
    /// The Shello keyboard, apart from the system keyboard, whose keys can stay in the accessibility
    /// tree while a hardware keyboard hides it, and which shows in the Shello keyboard's place when
    /// the stand-in is attached but the Simulator's own keyboard is not.
    @MainActor
    var shelloKeyboard: XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "Shello Keyboard")).firstMatch
    }

    /// The extra keys row, above whichever keyboard is up, or alone.
    @MainActor
    var extraKeysRow: XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "Extra Keys")).firstMatch
    }

    /// Taps the terminal until the Shello keyboard shows, at most three times, waiting 15 seconds
    /// after each tap. In a CI run, the first test of its job on a simulator that had just started,
    /// the keyboard came 20 seconds after the tap, while the app's main thread stalled (`focus` in
    /// TestApp.swift); and on a slow runner a tap now and then goes nowhere (`typeInTerminal`).
    @MainActor
    func showShelloKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        let q = shelloKeyboard.keys["q"]
        for _ in 0..<3 where !q.exists {
            terminal.tap()
            _ = q.waitForExistence(timeout: 15)
        }
        XCTAssertTrue(q.exists, "The terminal doesn’t show the Shello keyboard", file: file, line: line)
    }

    /// Taps the terminal until it has the keyboard focus, at most three times, waiting 15 seconds
    /// after each tap, as `showShelloKeyboard()` does: for a terminal that shows no keys.
    @MainActor
    func focusTerminal(file: StaticString = #filePath, line: UInt = #line) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<3 {
            terminal.tap()
            let expectation = XCTNSPredicateExpectation(predicate: focused, object: terminal)
            if XCTWaiter.wait(for: [expectation], timeout: 15) == .completed {
                return
            }
        }
        XCTFail("The terminal doesn’t take the keyboard focus", file: file, line: line)
    }

    /// Turns the switch `toggle` off with a tap on the switch itself, and taps again while it stays
    /// on, at most three times, as `turnOn(_:)` does.
    @MainActor
    func turnOff(_ toggle: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let isOff = NSPredicate(format: "value == %@", "0")
        for _ in 0..<3 {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let turnedOff = XCTNSPredicateExpectation(predicate: isOff, object: toggle)
            if XCTWaiter.wait(for: [turnedOff], timeout: 5) == .completed {
                return
            }
        }
        XCTFail("\(toggle) stays on", file: file, line: line)
    }
}
