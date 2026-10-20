import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testFirstScreenPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launch()

        try app.performAccessibilityAudit()
    }

    /// libssh and OpenSSL are linked and run inside the app.
    @MainActor
    func testFirstScreenShowsPostQuantumKeyExchanges() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["mlkem768x25519-sha256"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["sntrup761x25519-sha512"].exists)
    }
}
