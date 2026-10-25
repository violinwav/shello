import XCTest

/// Jump hosts (README section 3): a host's jump hosts are chosen in the host editor, on a screen of
/// their own, among the saved SSH hosts; the host's details show its route; Connect goes through
/// the jump host, asking to trust each hop's host key, the hop named, to the shell; and the
/// Connection sheet lists each hop's key exchange. Jump hosts are reordered without dragging, with
/// Reorder's buttons, and deleting one names the hosts that use it, which keep it as missing and do
/// not connect. Each new and changed screen is audited.
///
/// A row's menu, a long press away, is not tested: while a menu is up, the app never tells XCTest
/// that its animations are done, and each step waits a minute for them.
final class JumpHostTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Through the test server on port 2222 to the one without post-quantum key exchange: in Docker,
    /// by its container's name, with this Mac's sshd, as in CI, on the loopback's port 2224.
    @MainActor
    func testConnectingThroughAJumpHostOpensTheShell() throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        try XCTSkipUnless(TestServer.isClassicalRunning, TestServer.classicalNotRunning)
        let app = XCUIApplication.launchWithEmptyDatabase(
            environment: ["SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue])
        try app.addJumpTestHost(name: "bastion", address: TestServer.address, port: TestServer.port)
        XCTAssertTrue(app.buttons["bastion"].firstMatch.waitForExistence(timeout: 5))

        try app.addJumpTestHost(
            name: TestServer.hostName, address: TestServer.behindJumpHost.address,
            port: TestServer.behindJumpHost.port, jumpHosts: ["bastion"], auditing: true)
        let row = app.buttons[TestServer.hostName].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars[TestServer.hostName].waitForExistence(timeout: 5))
        let route = app.routeRow
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        XCTAssertEqual(route.value as? String, "bastion, then \(TestServer.hostName)")
        try app.auditAccessibility()

        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        XCTAssertTrue(app.introduction(beginningWith: "Shello hasn’t connected to bastion, at localhost:2222").exists)
        try app.auditAccessibility()
        trustSheet.buttons["Trust"].tap()
        // The host behind it, as bastion reaches it.
        XCTAssertTrue(
            app.introduction(
                beginningWith:
                    "Shello hasn’t connected to \(TestServer.hostName) before. The jump host bastion reaches it"
            ).waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()
        XCTAssertTrue(app.connectionStatus(containing: "Connecting").waitForNonExistence(timeout: 30))
        XCTAssertFalse(app.connectionStatus(containing: "Couldn’t").exists)

        // The host's own connection has no post-quantum key exchange; bastion's has.
        app.openConnectionSheet(marked: "Classical Key Exchange")
        XCTAssertTrue(app.staticTexts["Post-Quantum Key Exchange"].exists)
        XCTAssertEqual(app.keyExchangeAlgorithms.count, 2)
        try app.auditAccessibility()
        app.navigationBars["Connection"].buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Connection"].waitForNonExistence(timeout: 5))

        // What the keyboard types runs on the server behind the jump host.
        app.terminal.tap()
        XCTAssertTrue(app.keys["u"].waitForExistence(timeout: 10))
        for key in ["u", "n", "a", "m", "e", "Return"] {
            app.keys[key].tap()
        }
        XCTAssertTrue(app.waitForTerminalText(TestServer.kernelName))
        app.closeTab()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }

    /// The jump hosts screen with two jump hosts, reordered with Reorder's Move Up button; the
    /// editor's row; deleting a jump host, whose confirmation names the host that uses it; and that
    /// host's route with the jump host missing, which refuses to connect and says why. Needs no
    /// server: nothing goes over the network.
    @MainActor
    func testJumpHostsAreReorderedAndADeletedOneStaysMissing() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addHost(name: "gateway", address: "gateway.example.com", user: "jump")
        app.addHost(name: "bastion", address: "bastion.example.com", user: "jump")
        app.buttons["Add Host"].firstMatch.tap()
        app.enter("web-01", into: app.textFields["Name"])
        app.enter("10.0.1.21", into: app.textFields["Address"])
        app.putKeyboardAway(after: "deploy", in: app.textFields["User"])
        try app.chooseJumpHosts(["gateway", "bastion"], auditing: true)
        let rows = app.jumpHostRows
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.element(boundBy: 1).label, "bastion")

        // Reorder: the moves are buttons, the first jump host has no Move Up, and adding waits.
        let screen = app.navigationBars["Jump Hosts"]
        screen.buttons["Reorder"].tap()
        let moveUp = app.buttons["Move bastion Up"]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Move gateway Up"].exists)
        XCTAssertFalse(app.buttons["Add Jump Host…"].exists)
        try app.auditAccessibility()
        moveUp.tap()
        XCTAssertEqual(rows.element(boundBy: 0).label, "bastion")
        XCTAssertTrue((rows.element(boundBy: 0).value as? String)?.hasPrefix("1 of 2") == true)
        XCTAssertFalse(app.buttons["Move bastion Up"].exists)
        XCTAssertTrue(app.buttons["Move gateway Up"].exists)
        screen.buttons["Done"].tap()
        XCTAssertTrue(screen.buttons["Reorder"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Move gateway Up"].exists)
        screen.buttons.element(boundBy: 0).tap()
        let jumpHosts = app.buttons["Jump hosts"]
        XCTAssertTrue(jumpHosts.waitForExistence(timeout: 5))
        XCTAssertEqual(jumpHosts.value as? String, "bastion, then gateway")
        app.navigationBars["New Host"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 5))

        // Deleting gateway names web-01, which jumps through it.
        let gateway = app.buttons["gateway"].firstMatch
        gateway.swipeLeft()
        app.buttons["Delete"].tap()
        let confirm = app.buttons["Delete Host"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "web-01 connects through it")).firstMatch
                .exists)
        try app.auditAlertAccessibility()
        confirm.tap()
        XCTAssertTrue(gateway.waitForNonExistence(timeout: 5))

        app.buttons["web-01"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["web-01"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.routeRow.value as? String, "bastion, then Missing host, then web-01")
        XCTAssertTrue(
            app.staticTexts[
                "One of its jump hosts was deleted. Shello doesn’t connect to this host until you change "
                    + "its jump hosts."
            ].exists)
        try app.auditAccessibility()

        // A missing jump host never means connecting directly.
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.connectionStatus(containing: "jump hosts was deleted").waitForExistence(timeout: 10))
        try app.auditAccessibility()
        app.closeTab()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }
}

extension TestServer {
    /// The test server without post-quantum key exchange as the one on port 2222 reaches it
    /// (TestServers/README.md): in Docker, by its container's name on the servers' network; this
    /// Mac's own sshd reaches its other port on the loopback.
    static var behindJumpHost: (address: String, port: Int) {
        user == "shello" ? ("shello-test-openssh-classical", 22) : ("127.0.0.1", classicalPort)
    }

    /// What `uname` prints on the server behind the jump host: Linux in Docker, macOS's kernel for
    /// this Mac's own sshd.
    static var kernelName: String {
        user == "shello" ? "Linux" : "Darwin"
    }
}

extension XCUIApplication {
    /// Adds the host `name` for the test server at `address` and `port`, signing in as the test user
    /// with the SSH key `shello-test-client`, through `jumpHosts`, saved hosts chosen by name. The
    /// key goes first, and the jump hosts last, once the keyboard is away: their row is far down the
    /// form, which stays there when their screen goes back to it. `auditing` audits the editor with
    /// the row; `testJumpHostsAreReorderedAndADeletedOneStaysMissing` audits the jump hosts screen
    /// and its picker.
    @MainActor
    func addJumpTestHost(
        name: String, address: String, port: Int, jumpHosts: [String] = [], auditing: Bool = false
    ) throws {
        buttons["Add Host"].firstMatch.tap()
        let sshKey = picker("SSH Key")
        reveal(sshKey)
        sshKey.tap()
        XCTAssertTrue(navigationBars["SSH Key"].waitForExistence(timeout: 5))
        buttons["shello-test-client"].tap()
        XCTAssertTrue(navigationBars["New Host"].waitForExistence(timeout: 5))
        enter(name, into: textFields["Name"])
        enter(address, into: textFields["Address"])
        replace(with: String(port), in: textFields["Port"])
        putKeyboardAway(after: TestServer.user, in: textFields["User"])
        if !jumpHosts.isEmpty {
            try chooseJumpHosts(jumpHosts)
            navigationBars["Jump Hosts"].buttons.element(boundBy: 0).tap()
            let row = buttons["Jump hosts"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertEqual(row.value as? String, jumpHosts.joined(separator: ", then "))
            if auditing {
                reveal(row)
                try auditAccessibility(scrolled: true)
            }
        }
        navigationBars["New Host"].buttons["Save"].tap()
        XCTAssertTrue(navigationBars["Hosts"].waitForExistence(timeout: 5))
    }

    /// Types `text` into the host editor's user field, then Return, which puts the keyboard away
    /// there, since no field comes after it.
    @MainActor
    func putKeyboardAway(after text: String, in field: XCUIElement) {
        enter(text + "\n", into: field)
        XCTAssertTrue(keyboards.firstMatch.waitForNonExistence(timeout: 10))
    }

    /// In the open host editor, opens the jump hosts screen and adds `names`, in order, each from
    /// its picker, and stays on the screen. `auditing` audits the picker, the first time, and the
    /// screen with its jump hosts.
    @MainActor
    func chooseJumpHosts(_ names: [String], auditing: Bool = false) throws {
        let row = buttons["Jump hosts"]
        reveal(row)
        row.tap()
        let screen = navigationBars["Jump Hosts"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        for (index, name) in names.enumerated() {
            buttons["Add Jump Host…"].tap()
            XCTAssertTrue(navigationBars["Add Jump Host"].waitForExistence(timeout: 5))
            if auditing, index == 0 {
                try auditAccessibility()
            }
            // The picker's, not the host list's behind the sheet.
            jumpHostChoices.matching(NSPredicate(format: "label == %@", name)).firstMatch.tap()
            XCTAssertTrue(screen.waitForExistence(timeout: 5))
        }
        XCTAssertEqual(jumpHostRows.count, names.count)
        if auditing {
            try auditAccessibility()
        }
    }

    /// The hosts the jump host picker offers.
    @MainActor
    var jumpHostChoices: XCUIElementQuery {
        descendants(matching: .any).matching(identifier: "jump-host-choice")
    }

    /// The jump hosts screen's rows, in order.
    @MainActor
    var jumpHostRows: XCUIElementQuery {
        descendants(matching: .any).matching(identifier: "jump-host")
    }

    /// The route on a host's details.
    @MainActor
    var routeRow: XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Route")).firstMatch
    }

    /// The trust sheet's first text, while it begins with `text`.
    @MainActor
    func introduction(beginningWith text: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    /// The key exchanges' names on the connection sheet.
    @MainActor
    var keyExchangeAlgorithms: XCUIElementQuery {
        descendants(matching: .any).matching(identifier: "key-exchange")
    }
}
