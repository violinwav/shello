import XCTest

/// Restore (README section 4, GLOSSARY): once Shello was terminated, the host list's Live section
/// offers the tabs the window had open, and nothing connects until the user taps. Against the test
/// server, through a proxy that counts Shello's connections: two tabs of a host that attaches a tmux
/// session of the test's own, the first one selected; Shello terminated, then launched again with its
/// data; Restore brings both tabs back with the first selected, which connects at once while the
/// second waits until it is selected, and each shows the tmux session as it was. The host list with
/// the tabs to restore is audited. Skipped when the server is not running, or has no tmux.
final class RestoreTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRestoreReconnectsBothTabsToTheirTmuxSession() async throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        let proxy = try await FaultyProxy(to: UInt16(TestServer.port))
        let app = XCUIApplication.launchWithEmptyDatabase(
            environment: ["SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue],
            keepingDataAs: UUID().uuidString)
        // Output that only this test prints: the command typed has two spaces between its words,
        // and echo prints one.
        let words = (Self.randomLetters(4), Self.randomLetters(4))
        let output = "\(words.0) \(words.1)"
        app.addKeyHost(address: "127.0.0.1", port: Int(proxy.port), tmuxSession: "restore" + Self.randomLetters(6))
        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()
        let first = TestServer.hostName
        let second = "\(TestServer.hostName) (2)"
        XCTAssertTrue(app.tab(first, connections: 1).waitForExistence(timeout: 30))
        if app.waitForTerminalText("plain shell", timeout: 1) {
            throw XCTSkip("The test server has no tmux.")
        }
        app.typeInTerminal("echo \(words.0)  \(words.1)\n")
        XCTAssertTrue(app.waitForTerminalText(output))
        app.buttons["New Tab"].tap()
        XCTAssertTrue(app.tab(second, connections: 1).waitForExistence(timeout: 30))
        app.tab(first).tap()
        XCTAssertTrue(app.tab(first).wait(for: \.isSelected, toEqual: true, timeout: 5))

        app.terminate()
        XCTAssertTrue(proxy.waitUntilNoConnectionIsOpen(timeout: 30), "The tabs' connections stay open")
        app.launch()

        // Offered, and nothing connects until the tap. A slow runner takes a while to launch Shello.
        let restore = app.buttons["Restore 2 Tabs"]
        XCTAssertTrue(restore.waitForExistence(timeout: 30))
        let names = restore.value as? String ?? ""
        XCTAssertTrue(names.hasPrefix("\(first) ") && names.hasSuffix(" \(second)"), names)
        XCTAssertTrue(app.buttons["Restore \(first)"].exists)
        XCTAssertTrue(app.buttons["Restore \(second)"].exists)
        XCTAssertTrue(app.buttons["Don’t Restore"].exists)
        XCTContext.runActivity(named: "The tabs to restore") { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        try app.auditAccessibility()
        XCTAssertEqual(proxy.acceptedConnectionCount, 2, "A tab connected before Restore was tapped")

        restore.tap()
        // The first tab, selected as before, connects at once and shows its tmux session as it was.
        XCTAssertTrue(app.tab(first, connections: 1).waitForExistence(timeout: 30))
        XCTAssertTrue(app.tab(first).isSelected)
        XCTAssertTrue(app.tab(second, connections: 0).exists)
        // tmux draws its window once the attach command, typed after the prompt, has run.
        XCTAssertTrue(app.waitForTerminalText(output, timeout: 30))
        XCTAssertEqual(proxy.acceptedConnectionCount, 3)
        // The second waits until it is selected.
        app.tab(second).tap()
        XCTAssertTrue(app.tab(second, connections: 1).waitForExistence(timeout: 30))
        XCTAssertTrue(app.waitForTerminalText(output, timeout: 30))
        XCTAssertEqual(proxy.acceptedConnectionCount, 4)
    }

    private static func randomLetters(_ count: Int) -> String {
        String((0..<count).compactMap { _ in "abcdefghijklmnopqrstuvwxyz".randomElement() })
    }
}

extension XCUIApplication {
    /// Types `text` into the selected tab's terminal on the Shello keyboard, key by key: letters, a
    /// space as Space, and a line break as Return.
    @MainActor
    func typeInTerminal(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        terminal.tap()
        XCTAssertTrue(keys["Space"].waitForExistence(timeout: 10), file: file, line: line)
        for character in text {
            let key =
                switch character {
                case " ": "Space"
                case "\n": "Return"
                default: String(character)
                }
            keys[key].tap()
        }
    }
}
