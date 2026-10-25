import XCTest

/// The terminal (README section 5), attached to the terminal demo under Settings, Diagnostics:
/// search, selection and copy, paste and its confirmation, mouse clicks, the bell, and the font
/// size by pinch and by shortcut, with each screen audited. The terminal's own text is not in the
/// accessibility tree, so the tests read it through search: its counter says how often a text is
/// on screen or in the scrollback.
final class TerminalTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Search, then a long-press that selects a word and copies it, a paste of that word, and a
    /// paste of two lines, which asks first and says how many lines it has.
    @MainActor
    func testSearchCopyAndPaste() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.openTerminalDemo()
        let terminal = app.terminal
        XCTAssertEqual(terminal.label, "Terminal")
        try app.auditAccessibility()

        app.runDemo("Colors")
        // "demo$ colors", "16 colors" and "256 colors". The search finds the most recent first,
        // and Return goes on up, to the one before.
        app.search(for: "colors")
        XCTAssertTrue(app.staticTexts["2 of 3"].waitForExistence(timeout: 5))
        app.buttons["Previous Match"].tap()
        XCTAssertTrue(app.staticTexts["1 of 3"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
        app.buttons["Done"].tap()

        // The long-press selects the word under it: "Shello", in the first line.
        let changes = UIPasteboard.general.changeCount
        terminal.cell(column: 2, row: 0).press(forDuration: 1)
        app.editMenuItem("Copy").tap()
        XCTAssertGreaterThan(UIPasteboard.general.changeCount, changes)
        // A paste of one line goes at once: the demo echoes it at its prompt.
        app.longPressBelowTheOutput()
        app.editMenuItem("Paste").tap()
        app.search(for: "Shello")
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // Return, to run what the paste typed, then two lines from another app.
        app.runDemo("Clear")
        UIPasteboard.general.string = "size\nhelp"
        app.longPressBelowTheOutput()
        app.editMenuItem("Paste").tap()
        let confirmation = app.alerts["Paste 2 Lines?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        try app.auditAlertAccessibility()
        confirmation.buttons["Paste"].tap()
        // Each line ran as a command: size printed the grid.
        app.search(for: "columns,")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    /// In mouse mode, a tap is a click that the program receives; the bell rings; pinch and the
    /// font size shortcuts change the text size and show the new grid. At an accessibility text
    /// size, in dark mode, where the search bar's count and controls take lines of their own.
    @MainActor
    func testMouseClickBellAndFontSize() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(
            arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
            appearance: .dark)
        app.openTerminalDemo()
        let terminal = app.terminal
        try app.auditAccessibility()

        app.runDemo("Mouse Reporting")
        terminal.cell(column: 10, row: 20).tap()
        app.runDemo("Bell")
        // The demo prints each click it receives, with its cell. A longer term would not fit the
        // search field at this text size, which shows it cut short, and the audit reports that as
        // clipped text.
        app.search(for: "Click at")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
        app.buttons["Done"].tap()

        terminal.pinch(withScale: 1.6, velocity: 1)
        let feedback = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "point text")).firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertFalse(feedback.label.hasPrefix("13 point text"), "Pinch left the text size as it was")

        // Command-0 is Actual Size: back to 13 points. The simulator drops the first key from a
        // hardware keyboard after the on-screen keyboard typed, here the search: Shift goes first.
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        app.typeKey("0", modifierFlags: .command)
        let actualSize = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "13 point text"))
            .firstMatch
        XCTAssertTrue(actualSize.waitForExistence(timeout: 5))
        app.assertAppearance(.dark)
    }
}

extension XCUIApplication {
    /// The terminal on screen.
    @MainActor
    var terminal: XCUIElement {
        descendants(matching: .any).matching(identifier: "terminal").firstMatch
    }

    /// Opens Settings, Diagnostics, Terminal Demo. Settings and Diagnostics are not audited here:
    /// their new rows are further down than a screen, and iOS 26 fades what scrolls under the
    /// navigation bar, which the audit reports as low contrast. LaunchTests audits both unscrolled.
    /// HardwareKeyboardTests checks that no extra Esc key is set, on the Hardware Keyboard screen.
    @MainActor
    func openTerminalDemo(file: StaticString = #filePath, line: UInt = #line) {
        openSettings()
        XCTAssertTrue(navigationBars["Settings"].waitForExistence(timeout: 5), file: file, line: line)
        openTerminalDemoFromSettings(file: file, line: line)
    }

    /// Opens Diagnostics, Terminal Demo from the open Settings sheet.
    @MainActor
    func openTerminalDemoFromSettings(file: StaticString = #filePath, line: UInt = #line) {
        let diagnostics = buttons["Diagnostics"]
        revealFarDown(diagnostics, file: file, line: line)
        diagnostics.tap()
        let demo = buttons["Terminal Demo"]
        revealFarDown(demo, file: file, line: line)
        demo.tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), file: file, line: line)
        // The demo's welcome, then its prompt.
        settle()
    }

    /// `reveal(_:)` for a row near the end of a list that is many screens long at the largest text
    /// sizes, more than reveal(_:) scrolls: flicks towards the row first.
    @MainActor
    func revealFarDown(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var flicks = 0
        while !element.exists, flicks < 8 {
            swipeUp(velocity: .fast)
            flicks += 1
        }
        reveal(element, file: file, line: line)
    }

    /// Runs one of the demo's commands from its menu.
    @MainActor
    func runDemo(_ command: String) {
        buttons["Demo"].tap()
        let item = buttons[command]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
    }

    /// Opens the search bar and searches for `text`. Return puts the keyboard away, so that the
    /// screen can be audited.
    @MainActor
    func search(for text: String) {
        buttons["Search"].tap()
        let field = textFields["Search Terminal"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(text + "\n")
        XCTAssertTrue(keyboards.firstMatch.waitForNonExistence(timeout: 10))
    }

    /// An item of the terminal's edit menu.
    @MainActor
    func editMenuItem(_ title: String) -> XCUIElement {
        let item = descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ AND (elementType == %d OR elementType == %d)", title,
                XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)
        ).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) is not in the edit menu")
        return item
    }

    /// A long-press in the empty part of the terminal, which selects nothing and shows the menu
    /// with Paste.
    @MainActor
    func longPressBelowTheOutput() {
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).press(forDuration: 1)
    }
}

extension XCUIElement {
    /// The middle of a character cell of the terminal, counted from 0, at the default text size of
    /// 13 points: cells of 7.8 by about 16.6 points.
    @MainActor
    func cell(column: Int, row: Int) -> XCUICoordinate {
        coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: (Double(column) + 0.5) * 7.8, dy: (Double(row) + 0.5) * 16.6))
    }
}
