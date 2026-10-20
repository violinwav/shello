import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The first screen is the host list, empty on a new install.
    @MainActor
    func testFirstScreenIsTheHostListAndPassesAccessibilityAudit() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()

        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No Hosts"].exists)
        try app.auditAccessibility()
    }

    /// libssh and OpenSSL are linked and run inside the app: Settings, Diagnostics lists the
    /// post-quantum key exchanges.
    @MainActor
    func testDiagnosticsShowPostQuantumKeyExchanges() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
        app.buttons["Diagnostics"].tap()

        XCTAssertTrue(app.staticTexts["mlkem768x25519-sha256"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["sntrup761x25519-sha512"].exists)
        try app.auditAccessibility()
    }

    /// The app opens its database in the App Group container when no test asks for an empty one.
    @MainActor
    func testAppOpensItsDatabaseInTheAppGroup() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Shello Can’t Open Its Database"].exists)
    }
}
