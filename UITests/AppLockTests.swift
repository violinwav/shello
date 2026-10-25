import XCTest

/// App lock and the privacy cover (README section 13), with Face ID enrolled in the simulator.
final class AppLockTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        SimulatedFaceID.enroll()
    }

    override func tearDown() {
        SimulatedFaceID.unenroll()
    }

    /// Shello opens locked and asks for Face ID. Cancelling leaves it locked, offering Unlock, and
    /// the enrolled face unlocks it.
    @MainActor
    func testLocksAtLaunchAndUnlocksWithFaceID() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(appLock: true)
        XCTAssertTrue(app.lockedScreen.waitForExistence(timeout: 10))
        // The host list is under the lock, hidden from VoiceOver too.
        XCTAssertFalse(app.navigationBars["Hosts"].exists)

        app.cancelFaceID()
        XCTAssertTrue(app.lockedScreen.exists)
        XCTAssertFalse(app.navigationBars["Hosts"].exists)
        app.assertAppearance(.light)
        try app.auditAccessibility()

        app.buttons["Unlock"].tap()
        app.unlockWithFaceID()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No Hosts"].exists)
    }

    @MainActor
    func testLockedScreenPassesAccessibilityAuditInDarkMode() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(appearance: .dark, appLock: true)
        XCTAssertTrue(app.lockedScreen.waitForExistence(timeout: 10))

        app.cancelFaceID()

        app.assertAppearance(.dark)
        try app.auditAccessibility()
    }

    @MainActor
    func testLockedScreenPassesAccessibilityAuditAtTheLargestTextSize() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(arguments: largestTextSize, appLock: true)
        XCTAssertTrue(app.lockedScreen.waitForExistence(timeout: 10))

        app.cancelFaceID()

        XCTAssertTrue(app.buttons["Unlock"].isHittable)
        try app.auditAccessibility()
    }

    /// Back within the timeout, a minute unless the user chooses another, Shello stays unlocked.
    /// With "Immediately" it locks as soon as it leaves, over the sheet the user was in, which is
    /// still there once they unlock.
    @MainActor
    func testLocksAgainAfterTheTimeoutAndNotBefore() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(appLock: true)
        XCTAssertTrue(app.lockedScreen.waitForExistence(timeout: 10))
        app.unlockWithFaceID()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))
        app.settle(for: 2)
        XCTAssertFalse(app.lockedScreen.exists)

        app.openSettings()
        let requireUnlock = app.picker("Require Unlock")
        XCTAssertTrue(requireUnlock.waitForExistence(timeout: 5))
        XCTAssertEqual(requireUnlock.label, "Require Unlock, After 1 Minute")
        app.choose("Immediately", in: "Require Unlock")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.lockedScreen.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Settings"].exists)

        app.unlockWithFaceID()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    /// The app switcher's snapshot must show none of Shello's screens. The cover goes over them,
    /// sheets included, whenever the scene is not active, as while Notification Center is down.
    @MainActor
    func testCoverHidesTheScreensWhileTheSceneIsInactive() {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.buttons["Add Host"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 5))
        let cover = app.images["Shello"]
        XCTAssertFalse(cover.exists)

        // Notification Center comes down. In a CI run, in the first test since the simulator started,
        // the pull went nowhere, and the screen did not change: it pulls again while the cover does
        // not show, at most three times.
        let springboard = XCUIApplication.springboard
        for _ in 0..<3 where !cover.exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0)).press(
                forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
            _ = cover.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(cover.exists, "Notification Center does not come down")

        // Notification Center goes back up, as the user pushes it, and Shello is active again. Home
        // with Notification Center down is unpredictable: here it only closes Notification Center,
        // and on a slow CI runner it did so nine seconds late and then went on to the Home Screen,
        // after the test had brought Shello back.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)).press(
            forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertTrue(cover.waitForNonExistence(timeout: 20))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.navigationBars["New Host"].exists)
    }

    /// The cover itself, on its own: XCUITest cannot audit an app while its scene is inactive.
    @MainActor
    func testPrivacyCoverPassesAccessibilityAudit() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            let app = XCUIApplication.launchWithEmptyDatabase(
                appearance: appearance, environment: ["SHELLO_UI_TESTING_PRIVACY_COVER": "1"])
            XCTAssertTrue(app.images["Shello"].waitForExistence(timeout: 10))
            app.assertAppearance(appearance)
            try app.auditAccessibility()
            app.terminate()
        }
    }

    private let largestTextSize = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
}
