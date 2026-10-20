import XCTest

extension XCUIApplication {
    /// Launches Shello with an empty database of its own, so that every test starts from no hosts.
    /// Debug builds only; see App/ShelloApp.swift.
    @MainActor
    static func launchWithEmptyDatabase(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHELLO_UI_TESTING"] = "1"
        app.launchArguments += arguments
        app.launch()
        return app
    }

    /// `performAccessibilityAudit()`, less one false positive of its Dynamic Type check. The check
    /// reports some SwiftUI text whose font does scale as "partially unsupported", seemingly at random,
    /// because it looks for UIKit's `adjustsFontForContentSizeCategory`, which SwiftUI text does not
    /// expose (https://developer.apple.com/forums/thread/828525). Only static text is let through:
    /// controls, and text in a font that does not scale, which is reported as "unsupported", still
    /// fail. `testTextGrowsWithDynamicType` checks the scaling directly. Each ignored issue is
    /// attached to the test's results.
    @MainActor
    func auditAccessibility() throws {
        // The audit reads the screen as it is drawn: a push or a sheet still moving in shows up as
        // low contrast or clipped text, on a slow CI runner especially. Give it time to settle.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "The screen settles")], timeout: 1)
        var ignored: [String] = []
        try performAccessibilityAudit { issue in
            let isFalsePositive =
                issue.auditType == .dynamicType
                && issue.compactDescription == "Dynamic Type font sizes are partially unsupported"
                && issue.element?.elementType == .staticText
            if isFalsePositive {
                ignored.append("\(issue.compactDescription): \(issue.element?.label ?? "?")")
            }
            return isFalsePositive
        }
        if !ignored.isEmpty {
            XCTContext.runActivity(named: "Ignored audit issues") { activity in
                activity.add(XCTAttachment(string: ignored.joined(separator: "\n")))
            }
        }
    }

    /// Fills in the host sheet's text fields that have a value here, and saves.
    @MainActor
    func addHost(name: String, address: String, port: String? = nil, user: String? = nil) {
        buttons["Add Host"].firstMatch.tap()
        enter(name, into: textFields["Name"])
        enter(address, into: textFields["Address"])
        if let port {
            replace(with: port, in: textFields["Port"])
        }
        if let user {
            enter(user, into: textFields["User"])
        }
        navigationBars["New Host"].buttons["Save"].tap()
        XCTAssertTrue(navigationBars["Hosts"].waitForExistence(timeout: 5))
    }

    @MainActor
    func enter(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    /// Scrolls down the screen, a little at a time, until `element` can be tapped. Lists create rows
    /// only as they scroll into view.
    @MainActor
    func reveal(_ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, "\(element) is not on screen")
    }

    /// Replaces a text field's value with `text`.
    @MainActor
    func replace(with text: String, in field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let length = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length) + text)
    }
}
