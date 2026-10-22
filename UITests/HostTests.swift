import XCTest

/// The host list and the host editor (README section 3).
final class HostTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateAndEditAHost() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()

        app.addHost(name: "prod-api-02", address: "10.0.4.22", port: "2222", user: "deploy")
        let row = app.buttons["prod-api-02"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "SSH, deploy at 10.0.4.22, port 2222")

        row.tap()
        app.navigationBars["prod-api-02"].buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 5))
        app.replace(with: "prod-api-03", in: app.textFields["Name"])
        app.navigationBars["Edit Host"].buttons["Save"].tap()

        XCTAssertTrue(app.navigationBars["prod-api-03"].waitForExistence(timeout: 5))
        app.navigationBars["prod-api-03"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["prod-api-03"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["prod-api-02"].exists)
    }

    /// The password goes into the Keychain, which the editor reads back: it says that a password is
    /// saved, and removing it takes it out of the Keychain.
    @MainActor
    func testPasswordIsKeptInTheKeychain() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.buttons["Add Host"].firstMatch.tap()
        // The method and the password first: while the keyboard is up, a tap on the picker only ends
        // the typing, and the keyboard can cover the password field.
        app.choose("Password", in: "Method")
        let password = app.secureTextFields["Password"]
        XCTAssertEqual(password.placeholderValue, "optional")
        // Audited while the field is empty: screenshots leave out what a secure field holds, so the
        // audit cannot see its contrast.
        try app.auditAccessibility()
        // Return puts the keyboard away.
        app.enter("hunter2\n", into: password)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        app.enter("vault", into: app.textFields["Name"])
        app.enter("vault.lan", into: app.textFields["Address"])
        app.navigationBars["New Host"].buttons["Save"].tap()

        app.buttons["vault"].firstMatch.tap()
        app.navigationBars["vault"].buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 5))
        app.reveal(password)
        XCTAssertEqual(password.placeholderValue, "saved")
        let remove = app.buttons["Remove Saved Password"]
        app.reveal(remove)
        try app.auditAccessibility()
        remove.tap()
        // The same row undoes the removal until the host is saved.
        let keep = app.buttons["Keep Saved Password"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertEqual(password.placeholderValue, "optional")
        try app.auditAccessibility()
        app.navigationBars["Edit Host"].buttons["Save"].tap()

        app.navigationBars["vault"].buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 5))
        app.reveal(password)
        XCTAssertEqual(password.placeholderValue, "optional")
        XCTAssertFalse(remove.exists)
        XCTAssertFalse(keep.exists)
    }

    @MainActor
    func testNewHostEditorPassesAccessibilityAudit() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()

        app.buttons["Add Host"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
    }

    @MainActor
    func testNewTagScreenPassesAccessibilityAudit() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.buttons["Add Host"].firstMatch.tap()
        app.enter("nas", into: app.textFields["Name"])
        app.reveal(app.buttons["New Tag…"])
        app.buttons["New Tag…"].tap()
        XCTAssertTrue(app.navigationBars["New Tag"].waitForExistence(timeout: 5))

        // The name field takes the focus. Return in the empty field puts the keyboard away and adds
        // nothing; the audit then sees the screen at rest. Its Dynamic Type check passes on a slow
        // runner too since the app applies each text size at once
        // (DesignSystem.applyTextSizeChangesAtOnce).
        app.textFields["Tag Name"].typeText("\n")
        XCTAssertTrue(app.navigationBars["New Tag"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))

        try app.auditAccessibility()
    }

    /// A host with a group, a tag and a favourite fills every kind of section and row.
    @MainActor
    func testListDetailsAndEditorOfATaggedHostPassAccessibilityAudit() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addTaggedFavorite()

        try app.auditAccessibility()

        app.buttons["nas"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["nas"].waitForExistence(timeout: 5))
        try app.auditAccessibility()

        app.navigationBars["nas"].buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
    }

    @MainActor
    func testScreensPassAccessibilityAuditInDarkMode() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(appearance: .dark)
        app.addTaggedFavorite()

        app.assertAppearance(.dark)
        try app.auditAccessibility()

        app.buttons["nas"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["nas"].waitForExistence(timeout: 5))
        try app.auditAccessibility()

        app.navigationBars["nas"].buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 5))
        // The sheet is dark too.
        app.assertAppearance(.dark)
        try app.auditAccessibility()
    }

    @MainActor
    func testScreensPassAccessibilityAuditAtTheLargestTextSize() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(arguments: largestTextSize)
        app.addHost(name: "prod-api-01", address: "10.0.4.21", user: "deploy")

        try app.auditAccessibility()

        app.buttons["prod-api-01"].tap()
        XCTAssertTrue(app.navigationBars["prod-api-01"].waitForExistence(timeout: 5))
        try app.auditAccessibility()

        app.navigationBars["prod-api-01"].buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
    }

    /// The design's fonts scale with Dynamic Type: Geist for labels, JetBrains Mono for section
    /// headers and for what the user types.
    @MainActor
    func testTextGrowsWithDynamicType() {
        let regular = editorTextHeights(XCUIApplication.launchWithEmptyDatabase())
        let largest = editorTextHeights(XCUIApplication.launchWithEmptyDatabase(arguments: largestTextSize))

        for (name, height) in regular {
            XCTAssertGreaterThan(largest[name] ?? 0, height * 1.5, "\(name) does not grow with Dynamic Type")
        }
    }

    @MainActor
    func testHostWithProblemsIsNotSavedAndSaysWhatIsWrong() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.buttons["Add Host"].firstMatch.tap()
        app.enter("nas", into: app.textFields["Name"])
        app.enter("nas lan", into: app.textFields["Address"])
        app.replace(with: "70000", in: app.textFields["Port"])

        app.navigationBars["New Host"].buttons["Save"].tap()

        XCTAssertTrue(
            app.staticTexts["Enter a hostname, an IPv4 address or an IPv6 address."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Enter a port from 1 to 65535."].exists)
        XCTAssertTrue(app.navigationBars["New Host"].exists)
        // Return in the last field puts the keyboard away, so that the audit sees the whole sheet.
        app.enter("\n", into: app.textFields["User"])
        try app.auditAccessibility()
    }

    @MainActor
    func testSearchAndTagFilterNarrowTheList() {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addTaggedFavorite()
        app.addHost(name: "prod-api-01", address: "10.0.4.21", user: "deploy")

        app.buttons["Staging"].tap()
        XCTAssertTrue(app.buttons["Staging"].isSelected)
        XCTAssertTrue(app.buttons["nas"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["prod-api-01"].exists)
        app.buttons["All Tags"].tap()
        XCTAssertTrue(app.buttons["prod-api-01"].waitForExistence(timeout: 5))

        let search = app.searchFields.firstMatch
        app.enter("10.0.4", into: search)
        XCTAssertTrue(app.buttons["prod-api-01"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nas"].exists)

        // Not audited: the audit flags the hit area of the system search field's clear button.
        search.typeText(".99")
        XCTAssertTrue(app.staticTexts["No Results for “10.0.4.99”"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDeletingAHostAsksFirst() {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addHost(name: "nas", address: "nas.lan")
        let row = app.buttons["nas"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        row.swipeLeft()
        app.buttons["Delete"].tap()
        let confirm = app.buttons["Delete Host"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.staticTexts["No Hosts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["nas"].exists)
    }

    private let largestTextSize = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    /// The heights of interface text, a section header and a text field in the new host sheet.
    @MainActor
    private func editorTextHeights(_ app: XCUIApplication) -> [String: CGFloat] {
        app.buttons["Add Host"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 5))
        let heights = [
            "interface text": app.staticTexts["Plain SSH-2. Works with any SSH server, with nothing to set up on it."]
                .frame.height,
            "section header": app.staticTexts["Connection"].frame.height,
            "text field": app.textFields["Name"].frame.height,
        ]
        app.terminate()
        return heights
    }
}
