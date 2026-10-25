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

    /// libssh and OpenSSL are linked and run inside the app: Settings, Diagnostics shows libssh's
    /// version and what the algorithm policy offers, the post-quantum key exchanges first and marked
    /// in words (README section 14), then the ciphers.
    @MainActor
    func testDiagnosticsShowTheAlgorithmPolicy() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()

        app.openSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
        // Below the terminal's settings, further down than the first screen.
        let diagnostics = app.buttons["Diagnostics"]
        app.reveal(diagnostics)
        diagnostics.tap()

        let mlkem = app.staticTexts["mlkem768x25519-sha256"]
        XCTAssertTrue(mlkem.waitForExistence(timeout: 10))
        XCTAssertEqual(mlkem.value as? String, "Post-quantum")
        XCTAssertTrue(app.staticTexts["sntrup761x25519-sha512"].exists)
        try app.auditAccessibility()
        let chacha = app.staticTexts["chacha20-poly1305 at openssh.com"]
        app.reveal(chacha)
        XCTAssertTrue(chacha.exists)
    }

    /// The app opens its database in the App Group container when no test asks for an empty one.
    /// App lock stays off, so that the host list shows whatever the simulator's Face ID.
    @MainActor
    func testAppOpensItsDatabaseInTheAppGroup() {
        let app = XCUIApplication()
        app.launchEnvironment["SHELLO_UI_TESTING_APP_LOCK"] = "0"
        app.launch()

        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Shello Can’t Open Its Database"].exists)
    }
}
