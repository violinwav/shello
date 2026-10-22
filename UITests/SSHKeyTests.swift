import XCTest

/// SSH keys (README section 13): making one, copying and sharing its public key, and choosing it in
/// the host editor. UI tests keep SSH keys in memory, so every launch starts without any. The
/// simulator makes no Secure Enclave keys: keys are Ed25519 unless a test asks for the Secure
/// Enclave's stand-in.
final class SSHKeyTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The acceptance criterion: a key is made, listed, and its public key copied and shared, with
    /// each screen audited on the way.
    @MainActor
    func testCreateAKeyAndCopyAndShareItsPublicKey() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.openSettings()
        let sshKeys = app.buttons["SSH Keys"]
        app.reveal(sshKeys)
        sshKeys.tap()
        XCTAssertTrue(app.staticTexts["No SSH Keys"].waitForExistence(timeout: 5))
        try app.auditAccessibility()

        app.buttons["New SSH Key"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New SSH Key"].waitForExistence(timeout: 5))
        // The simulator makes Ed25519 keys only, and says why.
        XCTAssertTrue(app.staticTexts.beginning(with: "This device can’t make Secure Enclave keys").exists)
        XCTAssertFalse(app.buttons["Secure Enclave"].exists)
        // "Every use" warns that every reconnect asks (README section 13).
        XCTAssertTrue(app.buttons["While Shello Is Unlocked"].isSelected)
        app.buttons["On Every Use"].tap()
        XCTAssertTrue(app.buttons["On Every Use"].isSelected)
        XCTAssertTrue(app.staticTexts.beginning(with: "Every connection and every reconnect with this key").exists)
        try app.auditAccessibility()
        app.replace(with: "ci-deploy", in: app.textFields["Name"])
        app.navigationBars["New SSH Key"].buttons["Create"].tap()

        let row = app.buttons["ci-deploy"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "Ed25519 in the Keychain, asks on every use")
        try app.auditAccessibility()

        row.tap()
        XCTAssertTrue(app.navigationBars["ci-deploy"].waitForExistence(timeout: 5))
        // VoiceOver hears what the public key is, rather than its base64.
        XCTAssertTrue(app.staticTexts["Ed25519 public key, ci-deploy"].exists)
        XCTAssertTrue(app.staticTexts.beginning(with: "SHA256:").exists)
        try app.auditAccessibility()

        let changes = UIPasteboard.general.changeCount
        app.buttons["Copy Public Key"].tap()
        XCTAssertTrue(app.staticTexts["Copied the public key."].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(UIPasteboard.general.changeCount, changes)

        // The share sheet offers what it offers for text: Copy, Save to Files, and other apps.
        app.buttons["Share Public Key"].tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10))
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertTrue(shareSheet.waitForNonExistence(timeout: 10))
    }

    /// The host editor's SSH key is a choice of this device's keys, and a key made from there is
    /// chosen at once. The host's details then name it.
    @MainActor
    func testChooseAKeyForAHostAndMakeItFromTheHostEditor() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(appearance: .dark)
        app.buttons["Add Host"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 5))
        // The key first: while the keyboard is up, a tap on a row only ends the typing.
        let sshKey = app.picker("SSH Key")
        app.reveal(sshKey)
        XCTAssertEqual(sshKey.label, "SSH Key, None")
        sshKey.tap()

        XCTAssertTrue(app.navigationBars["SSH Key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["None"].isSelected)
        try app.auditAccessibility()
        app.buttons["New SSH Key…"].tap()
        XCTAssertTrue(app.navigationBars["New SSH Key"].waitForExistence(timeout: 5))
        app.replace(with: "homelab", in: app.textFields["Name"])
        app.navigationBars["New SSH Key"].buttons["Create"].tap()

        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.picker("SSH Key").label, "SSH Key, homelab")
        app.enter("nas", into: app.textFields["Name"])
        app.enter("nas.lan", into: app.textFields["Address"])
        app.navigationBars["New Host"].buttons["Save"].tap()

        app.buttons["nas"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["nas"].waitForExistence(timeout: 5))
        // The row reads its label and value together.
        XCTAssertTrue(app.staticTexts["SSH Key, homelab"].exists)
        app.assertAppearance(.dark)
        try app.auditAccessibility()
    }

    /// Where the device makes Secure Enclave keys, they are the default. At the largest text size,
    /// with the Secure Enclave's stand-in. Each screen is audited before it scrolls: iOS 26 fades what
    /// scrolls under a sheet's navigation bar, which the audit reports as low contrast.
    @MainActor
    func testSecureEnclaveKeyIsTheDefaultAtTheLargestTextSize() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(
            arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
            environment: ["SHELLO_UI_TESTING_SECURE_ENCLAVE": "1"])
        app.openSettings()
        let sshKeys = app.buttons["SSH Keys"]
        app.reveal(sshKeys)
        sshKeys.tap()
        // The empty state does not scroll: it must fit at the largest text size.
        XCTAssertTrue(app.staticTexts["No SSH Keys"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
        app.buttons["New SSH Key"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New SSH Key"].waitForExistence(timeout: 5))
        try app.auditAccessibility()

        let secureEnclave = app.buttons["Secure Enclave"]
        app.reveal(secureEnclave)
        XCTAssertTrue(secureEnclave.isSelected)
        XCTAssertFalse(app.buttons["Ed25519"].isSelected)
        let everyUse = app.buttons["On Every Use"]
        app.reveal(everyUse)
        XCTAssertTrue(app.buttons["While Shello Is Unlocked"].isSelected)
        everyUse.tap()
        XCTAssertTrue(everyUse.isSelected)
        app.reveal(app.staticTexts.beginning(with: "Every connection and every reconnect with this key"))
        app.navigationBars["New SSH Key"].buttons["Create"].tap()

        let row = app.buttons["Shello on iPhone"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "ECDSA P-256 in the Secure Enclave, asks on every use")
        try app.auditAccessibility()

        row.tap()
        XCTAssertTrue(app.navigationBars["Shello on iPhone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ECDSA P-256 public key, Shello on iPhone"].exists)
        try app.auditAccessibility()
    }
}

extension XCUIElementQuery {
    /// The first element whose label begins with `prefix`, for long texts: an identifier longer
    /// than 128 characters needs a predicate anyway.
    @MainActor
    func beginning(with prefix: String) -> XCUIElement {
        matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }
}
