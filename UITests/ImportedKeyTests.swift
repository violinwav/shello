import XCTest

/// Importing an SSH key and installing a key on a host (README section 13), each screen audited.
/// Importing needs no server. Installing does: it goes over the connection of a tab signed in with the
/// test server's client key, on port 2224, whose `~/.ssh/authorized_keys` is a container's in Docker
/// and, with this Mac's sshd as in CI, in the servers' own home directory, never the user's
/// (TestServers/local-sshd.sh).
final class ImportedKeyTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The acceptance criterion: an encrypted key pasted from the clipboard says what it is and asks
    /// for its passphrase; a wrong one says so; the right one imports it, and the list marks it
    /// imported. The clipboard is emptied. The key's details offer Install on Host, which without an
    /// open connection says how to get one.
    @MainActor
    func testImportAnEncryptedKeyWithItsPassphrase() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.openSettings()
        let sshKeys = app.buttons["SSH Keys"]
        app.reveal(sshKeys)
        sshKeys.tap()
        XCTAssertTrue(app.staticTexts["No SSH Keys"].waitForExistence(timeout: 5))

        app.buttons["Import SSH Key"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Import SSH Key"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Import SSH Key"].buttons["Import"].isEnabled)
        try app.auditAccessibility()

        // As the user copied the key from elsewhere. The system's Paste button pastes it without
        // asking whether Shello may.
        UIPasteboard.general.string = ImportFixture.encryptedKey
        let paste = app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        // The audit's text sizes can leave the form scrolled, with Paste under the navigation bar.
        app.reveal(paste)
        paste.tap()
        let privateKey = app.descendants(matching: .any)["Private Key"]
        XCTAssertTrue(privateKey.waitForExistence(timeout: 5))
        XCTAssertEqual(privateKey.value as? String, "OpenSSH Private Key, Encrypted, from the clipboard")
        let passphrase = app.secureTextFields["Passphrase"]
        XCTAssertTrue(passphrase.waitForExistence(timeout: 5))
        try app.auditAccessibility()

        // Return puts the keyboard away.
        app.enter("not-the-passphrase\n", into: passphrase)
        app.navigationBars["Import SSH Key"].buttons["Import"].tap()
        XCTAssertTrue(
            app.staticTexts["The passphrase isn’t right. Check it and try again."].waitForExistence(timeout: 15))
        app.replace(with: ImportFixture.passphrase + "\n", in: passphrase)
        app.replace(with: "laptop", in: app.textFields["Name"])
        app.navigationBars["Import SSH Key"].buttons["Import"].tap()

        let row = app.buttons["laptop"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertEqual(row.value as? String, "Imported ECDSA P-384 key in the Keychain")
        XCTAssertFalse(UIPasteboard.general.hasStrings, "The pasted key is still on the clipboard")
        try app.auditAccessibility()

        row.tap()
        XCTAssertTrue(app.navigationBars["laptop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ECDSA P-384 public key, laptop"].exists)
        try app.auditAccessibility()
        let install = app.buttons["Install on Host…"]
        app.reveal(install)
        install.tap()
        XCTAssertTrue(app.staticTexts["No Open Connections"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
        app.navigationBars["Install on Host"].buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["laptop"].waitForExistence(timeout: 5))
    }

    /// The import sheet in dark mode at the largest text size, before a key and with one: the key's
    /// description keeps the row's width, Remove goes under it with its name, and the passphrase's
    /// field stacks. Each is audited before the sheet scrolls.
    @MainActor
    func testImportSheetInDarkModeAtTheLargestTextSize() throws {
        let app = XCUIApplication.launchWithEmptyDatabase(
            arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
            appearance: .dark)
        app.openSettings()
        let sshKeys = app.buttons["SSH Keys"]
        app.reveal(sshKeys)
        sshKeys.tap()
        app.buttons["Import SSH Key"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Import SSH Key"].waitForExistence(timeout: 5))
        app.assertAppearance(.dark)
        try app.auditAccessibility()

        UIPasteboard.general.string = ImportFixture.encryptedKey
        defer { UIPasteboard.general.items = [] }
        let paste = app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        app.reveal(paste)
        paste.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Private Key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove Private Key"].exists)
        try app.auditAccessibility()
        app.navigationBars["Import SSH Key"].buttons["Cancel"].tap()
    }

    /// Install on Host goes over the open connection of a tab: the key's public key is added to the
    /// server's authorized_keys, and a second time the server has it already. Each says so.
    @MainActor
    func testInstallAKeyOnAHostOverItsConnection() throws {
        try XCTSkipUnless(TestServer.isClassicalRunning, TestServer.classicalNotRunning)
        let app = XCUIApplication.launchWithEmptyDatabase(
            environment: ["SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue])
        app.addKeyHost(port: TestServer.classicalPort)
        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()
        XCTAssertTrue(app.navigationBars[TestServer.hostName].buttons["Connection"].waitForExistence(timeout: 30))
        // Back to the host list, from the terminal screen and the host's details: the tab and its
        // connection stay.
        app.hostsButton.tap()
        XCTAssertTrue(app.buttons["Connection"].waitForNonExistence(timeout: 10))
        app.navigationBars[TestServer.hostName].buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))

        app.openSettings()
        let sshKeys = app.buttons["SSH Keys"]
        app.reveal(sshKeys)
        sshKeys.tap()
        app.buttons["New SSH Key"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New SSH Key"].waitForExistence(timeout: 5))
        app.replace(with: "phone-\(UUID().uuidString.prefix(8))", in: app.textFields["Name"])
        app.navigationBars["New SSH Key"].buttons["Create"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "phone-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let install = app.buttons["Install on Host…"]
        app.reveal(install)
        install.tap()

        // The host list behind the sheet has a button of the same name.
        let host = app.buttons["install-host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        XCTAssertEqual(host.label, TestServer.hostName)
        try app.auditAccessibility()
        host.tap()
        let added = app.staticTexts["Installed on \(TestServer.hostName): the key is in ~/.ssh/authorized_keys now."]
        XCTAssertTrue(added.waitForExistence(timeout: 30))
        XCTAssertTrue((host.value as? String)?.hasSuffix("Installed") == true, "\(host.value ?? "")")
        try app.auditAccessibility()

        host.tap()
        XCTAssertTrue(
            app.staticTexts["\(TestServer.hostName) has the key already. Nothing changed."].waitForExistence(
                timeout: 30))
        app.navigationBars["Install on Host"].buttons["Close"].tap()
    }
}

/// The key the import test pastes: Packages/ShelloKit/Tests/KeyFixtures/Keys/ecdsa-p384-openssh-encrypted,
/// a test fixture that ssh-keygen made, never anyone's key.
enum ImportFixture {
    static let encryptedKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABB3CDcVgj
        4B7Zg2/vjay/xrAAAAGAAAAAEAAACIAAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlz
        dHAzODQAAABhBGr90E+nS1nVpsdKB2syq1OcsS5oLKZi4Ap2X6v10VKe/W2c70wdcOlFZi
        WGZBteERdvhAKNVduHgSh7+vmNQtYGNUJG8M8+hPlAAA40p+Qo/1qnEtfbElAOJOAOjI5X
        GwAAAPB56sU4mv06K2ynQK1no/ijLV9xAkVChlEA+oTeERRtYiBtosU/3Ycwc3fC4x6tkX
        Sht79jpXJMSVQ3/DFcfmgXPJppwcPrwwNkgmpnC7VbCrHdm8ch41V8iIViweyKAmYtk2FK
        ztY5+bNGef0ez0Mj8VEzC0A9fBDoxIIWS79jFCeykQZy7Kgd/VfRLDVFRQGl9MdqktZVJ8
        TLQlrDNxmBFFL2P7c5jS3Oh0A3elIwP37dFJ/0i/Dgb+Hv3HxB8hJjB3ecl2mIAFalIw7k
        Qf6s4u6dSnQ15zPzrehag/S53WFSgCpRW0qdjXmwUfu8szw=
        -----END OPENSSH PRIVATE KEY-----

        """

    static let passphrase = "shello-fixture-passphrase"
}
