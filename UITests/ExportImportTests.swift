import XCTest

/// Export and import of all non-secret data as one JSON file (README section 15), through the
/// system's file exporter and importer and the Files app's On My iPhone.
final class ExportImportTests: XCTestCase {
    /// Once, before the first test: the importer must be able to pick what the exporter saves.
    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated { XCUIApplication.prepareFilesForPicking() }
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// The safety net against data loss: an export saved in Files brings every host, group and tag
    /// back into an empty database, after the user has confirmed what the file holds.
    @MainActor
    func testExportThenImportIntoAnEmptyDatabase() throws {
        let original = XCUIApplication.launchWithEmptyDatabase()
        original.addTaggedFavorite()
        original.openSettings()
        XCTAssertTrue(original.navigationBars["Settings"].waitForExistence(timeout: 5))

        let file = original.exportData()

        XCTAssertTrue(original.staticTexts["Exported 1 host, 1 group and 1 tag to “\(file)”."].exists)
        try original.auditAccessibility()
        original.terminate()

        let app = XCUIApplication.launchWithEmptyDatabase()
        XCTAssertTrue(app.staticTexts["No Hosts"].waitForExistence(timeout: 10))
        app.openSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        app.importData(named: file)

        let confirmation = app.alerts["Import 1 host, 1 group and 1 tag?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        // An identifier longer than 128 characters needs a predicate.
        let rule =
            "Hosts, groups and tags already in Shello are replaced by their version in the file. None of these are "
            + "in Shello yet. Nothing else changes."
        XCTAssertTrue(confirmation.staticTexts.matching(NSPredicate(format: "label == %@", rule)).firstMatch.exists)
        try app.auditAlertAccessibility()
        confirmation.buttons["Import"].tap()
        XCTAssertTrue(app.staticTexts["Imported 1 host, 1 group and 1 tag."].waitForExistence(timeout: 5))
        try app.auditAccessibility()

        app.navigationBars["Settings"].buttons["Close"].tap()
        let row = app.buttons["nas"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "SSH, admin at nas.lan, Favorite, Tags: Staging")
        // The group's section. The host list's headers read in capitals.
        let homelab = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Homelab")).firstMatch
        XCTAssertTrue(homelab.waitForExistence(timeout: 5))
    }

    /// Cancelling the confirmation imports nothing.
    @MainActor
    func testCancellingTheImportChangesNothing() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addHost(name: "prod-api-01", address: "10.0.4.21", user: "deploy")
        app.openSettings()
        let file = app.exportData()
        app.navigationBars["Settings"].buttons["Close"].tap()
        app.buttons["prod-api-01"].firstMatch.swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["Delete Host"].tap()
        XCTAssertTrue(app.staticTexts["No Hosts"].waitForExistence(timeout: 5))

        app.openSettings()
        app.importData(named: file)
        let confirmation = app.alerts["Import 1 host?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.buttons["Cancel"].tap()
        app.navigationBars["Settings"].buttons["Close"].tap()

        XCTAssertTrue(app.staticTexts["No Hosts"].waitForExistence(timeout: 5))
    }

    /// An export of an empty database is a valid file, which holds nothing to import.
    @MainActor
    func testImportingAFileWithoutHostsSaysThereIsNothingToImport() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.openSettings()
        let file = app.exportData()
        XCTAssertTrue(app.staticTexts["Exported no hosts, groups or tags to “\(file)”."].exists)

        app.importData(named: file)

        let alert = app.alerts["Nothing to Import"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["The file has no hosts, groups or tags."].exists)
        try app.auditAlertAccessibility()
        alert.buttons["OK"].tap()
    }

    @MainActor
    func testExportAndImportPassAccessibilityAuditInDarkMode() throws {
        try auditExportAndImport(XCUIApplication.launchWithEmptyDatabase(appearance: .dark), appearance: .dark)
    }

    @MainActor
    func testExportAndImportPassAccessibilityAuditAtTheLargestTextSize() throws {
        try auditExportAndImport(XCUIApplication.launchWithEmptyDatabase(arguments: largestTextSize))
    }

    /// Audits Settings before and after an export, with the result showing, and an alert of the import.
    @MainActor
    private func auditExportAndImport(_ app: XCUIApplication, appearance: XCUIDevice.Appearance = .light) throws {
        app.openSettings()
        XCTAssertTrue(app.buttons["Export Data…"].waitForExistence(timeout: 5))
        app.assertAppearance(appearance)
        try app.auditAccessibility()

        let file = app.exportData()
        XCTAssertTrue(app.staticTexts["Exported no hosts, groups or tags to “\(file)”."].exists)
        try app.auditAccessibility()

        app.importData(named: file)
        let alert = app.alerts["Nothing to Import"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        try app.auditAlertAccessibility()
        alert.buttons["OK"].tap()
    }

    private let largestTextSize = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
}
