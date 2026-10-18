import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testFirstScreenPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launch()

        try app.performAccessibilityAudit()
    }
}
