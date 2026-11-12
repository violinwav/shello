import XCTest

/// The Shello keyboard on the terminal demo (README section 6): typing, sticky Control with the
/// Shello keyboard and with the system keyboard, the switch between them, and the letters layout
/// from Settings, with the keyboard and its settings screen audited. The terminal's text is read
/// through search, as in TerminalTests.
final class KeyboardTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testShelloKeyboardTypesWithStickyControlOnBothKeyboards() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        // QWERTZ, whatever the simulator's own keyboard, on the Shello keyboard's settings screen.
        app.openSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let keyboardSettings = app.buttons["Shello Keyboard"]
        app.revealFarDown(keyboardSettings)
        keyboardSettings.tap()
        XCTAssertTrue(app.navigationBars["Shello Keyboard"].waitForExistence(timeout: 5))
        app.choose("QWERTZ", in: "Letters")
        try app.auditAccessibility()
        app.navigationBars["Shello Keyboard"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.openTerminalDemoFromSettings()

        // The Shello keyboard comes up with the terminal, Z in its top row.
        app.terminal.tap()
        let q = app.keys["q"]
        XCTAssertTrue(q.waitForExistence(timeout: 10))
        XCTAssertEqual(app.keys["z"].frame.midY, q.frame.midY, accuracy: 1)
        try app.auditAccessibility()

        for key in ["h", "e", "l", "p", "Return"] {
            app.keys[key].tap()
        }
        // Control on the extra keys row, then c: Control-C.
        let control = app.keys["Control"]
        control.tap()
        XCTAssertEqual(control.value as? String, "Armed")
        app.keys["c"].tap()
        XCTAssertNotEqual(control.value as? String, "Armed")

        // The system keyboard, with the same row above it: Control, then c on the system keyboard.
        app.keys["Switch to System Keyboard"].tap()
        XCTAssertTrue(app.keys["Switch to Shello Keyboard"].waitForExistence(timeout: 10))
        control.tap()
        app.typeText("c")
        app.keys["Switch to Shello Keyboard"].tap()
        XCTAssertTrue(q.waitForExistence(timeout: 10))

        // The demo ran help, and both keyboards' Control-C reached it: each gave a new prompt. The
        // search counts prompts rather than "^C", since a German keyboard types ^ as an accent.
        // Return in the search field goes on up from the latest match, to the one before.
        app.search(for: "fast as it")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.search(for: "demo$")
        XCTAssertTrue(app.staticTexts["3 of 4"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // Leaving the demo takes the keyboard away with the terminal.
        app.navigationBars["Terminal Demo"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(q.waitForNonExistence(timeout: 10))
    }
}
