import CryptoKit
import XCTest

/// The import from an OpenSSH config file and a known_hosts file (README section 3), picked in the
/// Files app's On My iPhone: the preview, with the hosts, their jump host, the host keys to trust,
/// and the lines Shello leaves out, each with its number; the import; the summary, which keeps those
/// lines listed; then a connection to the imported host through its imported jump host, which asks
/// to trust no host key, since the known_hosts file's keys are trusted, a hashed name's too. Each
/// screen is audited.
final class OpenSSHImportTests: XCTestCase {
    /// Once, before the first test: the importer must be able to pick what is in On My iPhone.
    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated { XCUIApplication.prepareFilesForPicking() }
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// Through the test server on port 2222 to the one without post-quantum key exchange, as
    /// `JumpHostTests` connects: in Docker, by its container's name, with this Mac's sshd, as in CI, on
    /// the loopback's port 2224.
    @MainActor
    func testImportedHostConnectsThroughItsImportedJumpHostWithoutATrustPrompt() throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        try XCTSkipUnless(TestServer.isClassicalRunning, TestServer.classicalNotRunning)
        try SampleFiles.write()
        let app = XCUIApplication.launchWithEmptyDatabase(
            environment: ["SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue])
        let sheet = try app.previewSampleFiles()

        // The hosts, the jump host first, with what they sign in with.
        let hosts = app.descendants(matching: .any).matching(identifier: "import-host")
        XCTAssertEqual(hosts.count, 2)
        XCTAssertEqual(hosts.element(boundBy: 0).label, "bastion")
        XCTAssertEqual(
            hosts.element(boundBy: 0).value as? String,
            "\(TestServer.user) at localhost, port 2222. SSH key: shello-test-client. Line 2")
        let behind = hosts.element(boundBy: 1)
        XCTAssertEqual(behind.label, "behind")
        let target = TestServer.behindJumpHost
        XCTAssertEqual(
            behind.value as? String,
            "\(TestServer.user) at \(target.address), port \(target.port). Through bastion. "
                + "SSH key: shello-test-client. Line 6")

        // The host keys, the hashed name's matched to the host behind the jump host.
        let keys = app.descendants(matching: .any).matching(identifier: "import-host-key")
        app.reveal(keys.element(boundBy: 1))
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.element(boundBy: 0).label, "localhost, port 2222")
        XCTAssertEqual(keys.element(boundBy: 1).label, "\(target.address), port \(target.port)")

        // The lines left out, with their numbers.
        let notImported = app.descendants(matching: .any).matching(identifier: "not-imported")
        app.reveal(notImported.element(boundBy: 1))
        XCTAssertEqual(notImported.count, 2)
        // VoiceOver hears why first; the line is in More Content.
        XCTAssertEqual(notImported.element(boundBy: 0).label, "config, line 13")
        XCTAssertEqual(notImported.element(boundBy: 0).value as? String, "Shello doesn’t import ForwardAgent.")
        XCTAssertEqual(notImported.element(boundBy: 1).label, "known_hosts, line 3")
        XCTAssertEqual(
            notImported.element(boundBy: 1).value as? String, "Shello trusts host keys, not certificate authorities.")
        try app.auditAccessibility(scrolled: true)

        try app.importSampleFiles(from: sheet)
        app.navigationBars["Settings"].buttons["Close"].tap()

        // The host behind the jump host connects, trusting both hops' keys without asking.
        let row = app.buttons["behind"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["behind"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.routeRow.value as? String, "bastion, then behind")
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.connectionStatus(containing: "Connecting").waitForNonExistence(timeout: 30))
        XCTAssertFalse(app.navigationBars["Trust This Server?"].exists)
        XCTAssertFalse(app.connectionStatus(containing: "Couldn’t").exists)
        app.terminal.tap()
        XCTAssertTrue(app.keys["u"].waitForExistence(timeout: 10))
        for key in ["u", "n", "a", "m", "e", "Return"] {
            app.keys[key].tap()
        }
        XCTAssertTrue(app.waitForTerminalText(TestServer.kernelName))
        XCTAssertFalse(app.navigationBars["Trust This Server?"].exists)
        app.closeTab()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }

    /// The import's screens at the largest text size: the sheet, the preview at its top and scrolled
    /// to its last line, and the summary. Needs no server: nothing connects.
    @MainActor
    func testImportScreensPassAccessibilityAuditAtTheLargestTextSize() throws {
        try SampleFiles.write()
        let app = XCUIApplication.launchWithEmptyDatabase(
            arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
            environment: ["SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue])
        let sheet = try app.previewSampleFiles()
        let notImported = app.descendants(matching: .any).matching(identifier: "not-imported")
        app.revealFarDown(notImported.element(boundBy: 1))
        try app.auditAccessibility(scrolled: true)
        try app.importSampleFiles(from: sheet)
    }
}

extension XCUIApplication {
    /// Opens Import from OpenSSH in Settings, audits it, and picks the sample config, then the sample
    /// known_hosts, waiting for the preview of each, and audits the preview at its top. Returns the
    /// sheet's navigation bar.
    @MainActor
    fileprivate func previewSampleFiles() throws -> XCUIElement {
        openSettings()
        let open = buttons["Import from OpenSSH…"]
        reveal(open)
        open.tap()
        let sheet = navigationBars["Import from OpenSSH"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertFalse(sheet.buttons["Import"].isEnabled)
        XCTAssertEqual(buttons["config-file"].value as? String, "None chosen")
        try auditAccessibility()

        pickFile(named: SampleFiles.configName, opening: buttons["config-file"])
        waitForFile("config-file", "\(SampleFiles.configName), 14 lines")
        pickFile(named: SampleFiles.knownHostsName, opening: buttons["known-hosts-file"])
        waitForFile("known-hosts-file", "\(SampleFiles.knownHostsName), 4 lines")
        try auditAccessibility()
        // Below the files: at the largest text size, a screen or more down.
        let overview = staticTexts["import-overview"]
        revealFarDown(overview)
        XCTAssertEqual(
            overview.label, "Import adds 2 hosts and trusts 2 host keys. 2 lines aren’t imported, as listed below.")
        return sheet
    }

    /// Waits until the file row `identifier` says it holds `value`: the file is read, and the preview
    /// planned.
    @MainActor
    private func waitForFile(_ identifier: String, _ value: String, file: StaticString = #filePath, line: UInt = #line)
    {
        let row = buttons.matching(NSPredicate(format: "identifier == %@ AND value == %@", identifier, value))
        XCTAssertTrue(
            row.firstMatch.waitForExistence(timeout: 15), "\(identifier) is not \(value)", file: file, line: line)
    }

    /// Taps the sheet's Import, checks and audits the summary at its top, checks that it keeps the
    /// lines left out listed, and closes it with Done.
    @MainActor
    fileprivate func importSampleFiles(from sheet: XCUIElement) throws {
        sheet.buttons["Import"].tap()
        let done = navigationBars["Imported from OpenSSH"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        let status = staticTexts["import-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Added 2 hosts and trusted 2 host keys.")
        try auditAccessibility()
        let lines = descendants(matching: .any).matching(identifier: "not-imported")
        // Its rows are the preview's, which the preview's audits covered, scrolled too. Scrolled to its
        // end, the audit took the last footer, close to the screen's bottom, for clipped text.
        revealFarDown(lines.element(boundBy: 1))
        XCTAssertEqual(lines.count, 2)
        done.buttons["Done"].tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }
}

/// The config and known_hosts files the test imports, written to On My iPhone, the simulator's own
/// files in the Files app, where the file importer finds them.
private enum SampleFiles {
    static let configName = "config"
    static let knownHostsName = "known_hosts"

    /// The config: a jump host on the test server's port 2222, and the host behind it, both signing
    /// in as the test user with the test client's key, `shello-test-client` among Shello's SSH keys,
    /// which the `Host *` block gives them. ForwardAgent, on line 13, is not imported.
    static var config: String {
        let target = TestServer.behindJumpHost
        return """
            # Shello's UI test: a jump host, and a host behind it.
            Host bastion
                HostName localhost
                Port 2222

            Host behind
                HostName \(target.address)
                Port \(target.port)
                ProxyJump bastion

            Host *
                User \(TestServer.user)
                ForwardAgent yes
                IdentityFile ~/.ssh/shello-test-client
            """
    }

    /// The known_hosts: host key a for the jump host's server, and for the server behind it under a
    /// hashed name, as `HashKnownHosts` writes it; and a certificate authority, on line 3, which is
    /// not imported.
    static var knownHosts: String {
        let target = TestServer.behindJumpHost
        let key = "\(TestServer.hostKeyA.algorithm) \(TestServer.hostKeyA.base64)"
        let name = target.port == 22 ? target.address : "[\(target.address)]:\(target.port)"
        let salt = Data((0..<20).map { UInt8($0 * 7 + 3) })
        let hash = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt)))
        return """
            [localhost]:2222 \(key)
            |1|\(salt.base64EncodedString())|\(hash.base64EncodedString()) \(key)
            @cert-authority *.example.com \(key)
            # The end.
            """
    }

    /// Writes both files to On My iPhone, replacing earlier ones. The simulator's processes reach its
    /// data folder, where the Files app keeps On My iPhone in the App Group of its local storage.
    static func write() throws {
        let folder = try onMyIPhone()
        try Data(config.utf8).write(to: folder.appending(path: configName))
        try Data(knownHosts.utf8).write(to: folder.appending(path: knownHostsName))
    }

    /// The folder of On My iPhone: the File Provider Storage of the App Group
    /// `group.com.apple.FileProvider.LocalStorage`, among the simulator's App Groups.
    private static func onMyIPhone() throws -> URL {
        let home = URL(filePath: NSHomeDirectory())
        let path = home.path(percentEncoded: false)
        guard let range = path.range(of: "/Containers/Data/") else {
            throw XCTSkip("This test runs in the iOS Simulator, whose On My iPhone it writes to.")
        }
        let groups = URL(filePath: String(path[..<range.lowerBound])).appending(path: "Containers/Shared/AppGroup")
        for group in try FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil) {
            let metadata = group.appending(path: ".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: metadata),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                plist["MCMMetadataIdentifier"] as? String == "group.com.apple.FileProvider.LocalStorage"
            else { continue }
            return group.appending(path: "File Provider Storage")
        }
        throw XCTSkip("On My iPhone's folder is not among the simulator's App Groups.")
    }
}
