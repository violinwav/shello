import Network
import Synchronization
import XCTest

/// Port forwards (README section 4): the host editor's Port Forwards section, where forwards are
/// added, edited, switched off and deleted, each on a screen of its own; and the Connection sheet,
/// which lists a connected tab's forwards with how each stands: listening on 127.0.0.1 and its port,
/// not listening and why, here a port this test already listens on, or off. A forward that listens
/// carries a connection from this test to the test server's sshd, whose banner the test reads. Each
/// new screen is audited.
final class PortForwardTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Needs no server: nothing goes over the network.
    @MainActor
    func testPortForwardsAreAddedEditedSwitchedOffAndDeleted() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.buttons["Add Host"].firstMatch.tap()
        app.enter("db-proxy", into: app.textFields["Name"])
        app.enter("db.example.com", into: app.textFields["Address"])
        app.putKeyboardAway(after: "deploy", in: app.textFields["User"])

        // Add without a port says what is missing, and adds nothing.
        app.openNewPortForward()
        app.navigationBars["New Port Forward"].buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Enter the port to listen on."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New Port Forward"].exists)
        app.fillPortForward(port: "15432", destination: ("db.internal", "5432"), name: "Database")
        try app.auditAccessibility()
        app.navigationBars["New Port Forward"].buttons["Add"].tap()
        let database = app.portForwardRow("Database")
        app.revealInEditor(database)
        XCTAssertEqual(database.value as? String, "Local forward, port 15432 to db.internal, port 5432")

        // A dynamic forward has no destination.
        app.openNewPortForward()
        app.buttons["Dynamic (SOCKS)"].tap()
        XCTAssertFalse(app.textFields["Destination address"].exists)
        app.fillPortForward(port: "1080")
        app.navigationBars["New Port Forward"].buttons["Add"].tap()
        let socks = app.portForwardRow("SOCKS Proxy")
        app.revealInEditor(socks)
        XCTAssertEqual(socks.value as? String, "Dynamic forward, SOCKS5 on port 1080")
        app.reveal(socks)
        try app.auditAccessibility(scrolled: true)

        // Switched off on its own screen, which is audited.
        app.reveal(database)
        database.tap()
        XCTAssertTrue(app.navigationBars["Port Forward"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
        let isOn = app.switches["Enabled"].firstMatch
        isOn.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(isOn.value as? String, "0")
        app.navigationBars["Port Forward"].buttons.element(boundBy: 0).tap()
        app.revealInEditor(database)
        XCTAssertEqual(database.value as? String, "Off. Local forward, port 15432 to db.internal, port 5432")

        // Deleted with a swipe.
        app.reveal(socks)
        socks.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(socks.waitForNonExistence(timeout: 5))

        app.navigationBars["New Host"].buttons["Save"].tap()
        let row = app.buttons["db-proxy"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.navigationBars["db-proxy"].buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 5))
        app.reveal(database)
        XCTAssertEqual(database.value as? String, "Off. Local forward, port 15432 to db.internal, port 5432")
        XCTAssertEqual(app.portForwardRows.count, 1)
    }

    /// A tab of a host with three forwards, to the test server's own sshd as the server reaches it:
    /// one listens, one finds its port already in use, by this test, and one is off. The Connection
    /// sheet says so for each, and a connection through the one that listens reads the sshd's banner.
    @MainActor
    func testConnectionSheetListsTheForwardsAndWhyOneDoesNotListen() async throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        let busy = try await LoopbackListener()
        let free = try await LoopbackListener.freePort()
        let app = XCUIApplication.launchWithEmptyDatabase(
            environment: ["SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue])
        let sshd = TestServer.ownSSHD
        app.buttons["Add Host"].firstMatch.tap()
        let sshKey = app.picker("SSH Key")
        app.reveal(sshKey)
        sshKey.tap()
        XCTAssertTrue(app.navigationBars["SSH Key"].waitForExistence(timeout: 5))
        app.buttons["shello-test-client"].tap()
        XCTAssertTrue(app.navigationBars["New Host"].waitForExistence(timeout: 5))
        app.enter(TestServer.hostName, into: app.textFields["Name"])
        app.enter(TestServer.address, into: app.textFields["Address"])
        app.replace(with: String(TestServer.port), in: app.textFields["Port"])
        app.putKeyboardAway(after: TestServer.user, in: app.textFields["User"])
        for (port, name) in [(free, "Server"), (busy.port, "Taken")] {
            app.openNewPortForward()
            app.fillPortForward(port: String(port), destination: (sshd.address, String(sshd.port)), name: name)
            app.navigationBars["New Port Forward"].buttons["Add"].tap()
            app.revealInEditor(app.portForwardRow(name))
        }
        app.openNewPortForward()
        app.buttons["Dynamic (SOCKS)"].tap()
        app.fillPortForward(port: "1080", name: "")
        app.switches["Enabled"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.navigationBars["New Port Forward"].buttons["Add"].tap()
        app.revealInEditor(app.portForwardRow("SOCKS Proxy"))
        app.navigationBars["New Host"].buttons["Save"].tap()
        let row = app.buttons[TestServer.hostName].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars[TestServer.hostName].waitForExistence(timeout: 5))

        app.buttons["Connect"].tap()
        app.trustHostKey()
        XCTAssertTrue(app.connectionStatus(containing: "Connecting").waitForNonExistence(timeout: 30))
        app.openConnectionSheet(marked: "Post-Quantum Key Exchange")
        let states = app.forwardStates
        XCTAssertTrue(states.element(boundBy: 2).waitForExistence(timeout: 5))
        let server = states.matching(NSPredicate(format: "label == %@", "Server")).firstMatch
        let listening = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                "Listening on 127.0.0.1, port \(free). Local forward, port \(free) to \(sshd.address), port \(sshd.port)."
            ),
            object: server)
        XCTAssertEqual(XCTWaiter.wait(for: [listening], timeout: 10), .completed, "\(server.value ?? "")")
        XCTAssertEqual(
            states.matching(NSPredicate(format: "label == %@", "Taken")).firstMatch.value as? String,
            "Not listening. Port \(busy.port) is in use by another tab or app. Local forward, port \(busy.port) to "
                + "\(sshd.address), port \(sshd.port).")
        XCTAssertEqual(
            states.matching(NSPredicate(format: "label == %@", "SOCKS Proxy")).firstMatch.value as? String,
            "Off. Dynamic forward, SOCKS5 on port 1080.")
        let banner = try await LoopbackListener.banner(port: free)
        XCTAssertTrue(banner.hasPrefix("SSH-2.0-OpenSSH_"), banner)
        try app.auditAccessibility()

        app.navigationBars["Connection"].buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Connection"].waitForNonExistence(timeout: 5))
        app.closeTab()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }
}

extension TestServer {
    /// The test server's own sshd as the server reaches it: in Docker, its port 22 on its own
    /// loopback; this Mac's sshd, as in CI, its port on the loopback.
    static var ownSSHD: (address: String, port: Int) {
        user == "shello" ? ("localhost", 22) : ("127.0.0.1", port)
    }
}

extension XCUIApplication {
    /// In the open host editor, opens the New Port Forward screen.
    @MainActor
    func openNewPortForward(file: StaticString = #filePath, line: UInt = #line) {
        let add = buttons["Add Port Forward…"]
        reveal(add, file: file, line: line)
        add.tap()
        XCTAssertTrue(navigationBars["New Port Forward"].waitForExistence(timeout: 5), file: file, line: line)
    }

    /// Fills in the open port forward screen as a user moves through it: the port it listens on, then
    /// with the number pad's Next, which its toolbar has, a local forward's destination, whose
    /// address's Return moves on to its port, and the name, whose Return puts the keyboard away: an
    /// empty name only puts it away. A tap on the fields below would go to the number pad's toolbar,
    /// which covers them.
    @MainActor
    func fillPortForward(port: String, destination: (address: String, port: String)? = nil, name: String? = nil) {
        replace(with: port, in: textFields["Local port"])
        if let destination {
            let address = textFields["Destination address"]
            moveOn(to: address)
            address.typeText(destination.address + "\n")
            let destinationPort = textFields["Destination port"]
            waitForKeyboardFocus(on: destinationPort)
            destinationPort.typeText(destination.port)
        }
        if let name {
            let field = textFields.matching(identifier: "forward-name").firstMatch
            moveOn(to: field)
            field.typeText(name + "\n")
            XCTAssertTrue(keyboards.firstMatch.waitForNonExistence(timeout: 10))
            settle()
        }
    }

    /// Taps the number pad's Next, and waits until `field` has the keyboard focus.
    @MainActor
    private func moveOn(to field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let next = buttons["Next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "The number pad has no Next", file: file, line: line)
        next.tap()
        waitForKeyboardFocus(on: field, file: file, line: line)
    }

    /// Waits until `field` has the keyboard focus; if it does not get it, taps it, once it is in
    /// view.
    @MainActor
    private func waitForKeyboardFocus(on field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 5)
            == .completed
        {
            return
        }
        reveal(field, file: file, line: line)
        field.tap()
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 5),
            .completed, "\(field) does not take the keyboard focus", file: file, line: line)
    }

    /// Back in the host editor, scrolls to `row`, which a list makes only once it scrolls into view.
    @MainActor
    func revealInEditor(_ row: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let editor = navigationBars.matching(NSPredicate(format: "identifier IN %@", ["New Host", "Edit Host"]))
        XCTAssertTrue(editor.firstMatch.waitForExistence(timeout: 5), file: file, line: line)
        settle()
        reveal(row, file: file, line: line)
        XCTAssertTrue(row.exists, file: file, line: line)
    }

    /// The host editor's port forwards, in order.
    @MainActor
    var portForwardRows: XCUIElementQuery {
        buttons.matching(identifier: "port-forward")
    }

    /// The host editor's port forward whose row's title is `title`.
    @MainActor
    func portForwardRow(_ title: String) -> XCUIElement {
        portForwardRows.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// The Connection sheet's port forwards, in order.
    @MainActor
    var forwardStates: XCUIElementQuery {
        descendants(matching: .any).matching(identifier: "forward-state")
    }
}

/// A listener of this test's own on the loopback, as another app's would be, which takes a port
/// that one of Shello's forwards then finds in use; and what the test asks of the loopback.
final class LoopbackListener: Sendable {
    let port: UInt16
    private let listener: NWListener

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        port = try await withCheckedThrowingContinuation { continuation in
            let isResumed = Mutex(false)
            let resume: @Sendable (Result<UInt16, any Error>) -> Void = { result in
                let isFirst = isResumed.withLock { isResumed in
                    defer { isResumed = true }
                    return !isResumed
                }
                if isFirst { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): resume(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { connection in connection.cancel() }
            listener.start(queue: DispatchQueue(label: "ch.shello.uitests.listener"))
        }
    }

    deinit {
        listener.cancel()
    }

    /// A port of the loopback that nothing listens on as this returns, which the system chose.
    static func freePort() async throws -> UInt16 {
        let taken = try await LoopbackListener()
        let port = taken.port
        taken.listener.cancel()
        try await Task.sleep(for: .milliseconds(500))
        return port
    }

    /// The first line that what listens on `port` of the loopback sends, such as an SSH banner.
    static func banner(port: UInt16) async throws -> String {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "ch.shello.uitests.banner"))
        defer { connection.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 8, maximumLength: 256) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self))
                }
            }
        }
    }
}
