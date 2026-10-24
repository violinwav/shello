import Network
import Synchronization
import XCTest

/// Tabs (README section 4) against the test server, signing in with the client key, as CI's sshd
/// allows: several tabs of one host, switching between them with a tap and Command-Shift-], Find
/// from the keyboard, going back to the host list with Hosts and Command-[ and to the tabs again
/// under Live, closing with Command-W and Close Tab;
/// the background closing the connection and the visible tab reconnecting on return, its scrollback
/// kept; and a network that drops, which shows "reconnecting". The terminal screen with its tab bar
/// and the host list with its Live section are audited. Skipped when the server is not running.
final class TabTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSeveralTabsSwitchCloseAndComeBackFromTheHostList() throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        let app = XCUIApplication.launchWithEmptyDatabase(
            environment: ["SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue])
        app.addKeyHost()
        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()
        XCTAssertTrue(app.connectionStatus(containing: "Connecting").waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.tab(TestServer.hostName).waitForExistence(timeout: 5))
        try app.auditAccessibility()

        // A second tab of the same host, which is trusted now.
        app.buttons["New Tab"].tap()
        let second = app.tab("\(TestServer.hostName) (2)")
        XCTAssertTrue(second.waitForExistence(timeout: 15))
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(trustSheet.exists)
        XCTAssertTrue(app.tab("\(TestServer.hostName) (2)", connections: 1).waitForExistence(timeout: 15))
        app.tab(TestServer.hostName).tap()
        XCTAssertTrue(app.tab(TestServer.hostName).wait(for: \.isSelected, toEqual: true, timeout: 5))
        // Next Tab, from a hardware keyboard. The simulator drops the first key from a hardware
        // keyboard, here the first since the app started: Shift goes first (TerminalTests).
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(second.wait(for: \.isSelected, toEqual: true, timeout: 5))
        // Find reaches the selected tab's terminal from the keyboard too.
        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["Search Terminal"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))

        // Back to the host list: the tabs stay, under Live.
        app.hostsButton.tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        let live = app.liveTab("\(TestServer.hostName) (2)")
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        XCTAssertTrue(app.liveTab(TestServer.hostName).exists)
        try app.auditAccessibility()
        live.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        XCTAssertTrue(second.isSelected)
        // Show Hosts, from the keyboard, as the terminal takes Esc.
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        live.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 10))

        // Command-W closes the selected tab; Close Tab the last one, and the terminal screen with it.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(second.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.tab(TestServer.hostName).isSelected)
        app.closeTab()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.liveTab(TestServer.hostName).exists)
    }

    /// In the background, the connection stays for the background time, here a second, then closes:
    /// the proxy between Shello and the server sees it end. Back in the foreground, the tab on screen
    /// reconnects at once, and the command typed before is still in its scrollback. (XCTest keeps
    /// the app from being suspended while it tests it, so the proxy tells when the connection went.)
    @MainActor
    func testBackgroundClosesTheConnectionAndTheVisibleTabReconnects() async throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        let proxy = try await FaultyProxy(to: UInt16(TestServer.port))
        let app = XCUIApplication.launchWithEmptyDatabase(
            environment: [
                "SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue,
                "SHELLO_UI_TESTING_BACKGROUND_SECONDS": "1",
            ])
        app.addKeyHost(address: "127.0.0.1", port: Int(proxy.port))
        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()
        XCTAssertTrue(app.tab(TestServer.hostName, connections: 1).waitForExistence(timeout: 15))
        app.terminal.tap()
        XCTAssertTrue(app.keys["u"].waitForExistence(timeout: 10))
        for key in ["u", "n", "a", "m", "e", "Return"] {
            app.keys[key].tap()
        }
        XCTAssertTrue(app.waitForTerminalText("uname"))
        XCTAssertEqual(proxy.openConnectionCount, 1)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(proxy.waitUntilNoConnectionIsOpen(timeout: 30), "The connection stays open in the background")
        app.activate()

        XCTAssertTrue(app.tab(TestServer.hostName, connections: 2).waitForExistence(timeout: 15))
        XCTAssertEqual(proxy.openConnectionCount, 1)
        XCTAssertTrue(app.waitForTerminalText("uname"))
        app.closeTab()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }

    /// A network that drops, here a proxy between Shello and the server that resets the connection
    /// and refuses new ones: the tab says it reconnects, tries, and waits before trying again, which
    /// Reconnect Now cuts short once the network is back.
    @MainActor
    func testDroppedNetworkShowsReconnectingThenReconnects() async throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        let proxy = try await FaultyProxy(to: UInt16(TestServer.port))
        let app = XCUIApplication.launchWithEmptyDatabase(
            environment: ["SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue])
        app.addKeyHost(address: "127.0.0.1", port: Int(proxy.port))
        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()
        XCTAssertTrue(app.tab(TestServer.hostName, connections: 1).waitForExistence(timeout: 15))

        proxy.cut()
        XCTAssertTrue(
            app.connectionStatus(containing: "Reconnecting to \(TestServer.hostName)").waitForExistence(timeout: 15))
        // Reconnect Now is there from the first try, and works between tries.
        let reconnectNow = app.buttons["Reconnect Now"]
        XCTAssertTrue(reconnectNow.waitForExistence(timeout: 15))
        XCTAssertTrue(reconnectNow.wait(for: \.isEnabled, toEqual: true, timeout: 15))
        proxy.restore()
        reconnectNow.tap()

        XCTAssertTrue(app.tab(TestServer.hostName, connections: 2).waitForExistence(timeout: 15))
        XCTAssertTrue(app.connectionStatus(containing: "Reconnecting").waitForNonExistence(timeout: 5))
        app.closeTab()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }
}

extension XCUIApplication {
    /// The terminal screen's Hosts button, which goes back to the host list. The host's details,
    /// behind the terminal screen, have a back button of the same name.
    @MainActor
    var hostsButton: XCUIElement {
        navigationBars[TestServer.hostName].buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Hosts", "BackButton")
        ).firstMatch
    }

    /// The tab named `name` in the tab bar.
    @MainActor
    func tab(_ name: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH %@", name, "tab, ")).firstMatch
    }

    /// The tab named `name`, once it has had `connections` connections: a reconnect makes one more.
    @MainActor
    func tab(_ name: String, connections: Int) -> XCUIElement {
        buttons.matching(
            NSPredicate(format: "label == %@ AND identifier == %@", name, "tab, connection \(connections)")
        ).firstMatch
    }

    /// The tab named `name` under Live in the host list, connected: its row says so after the host's
    /// name when the tab goes by another.
    @MainActor
    func liveTab(_ name: String) -> XCUIElement {
        buttons.matching(
            NSPredicate(
                format: "label == %@ AND (value BEGINSWITH %@ OR value CONTAINS %@)", name, "Connected",
                ", Connected")
        ).firstMatch
    }
}

/// A TCP proxy on this device's loopback between Shello and the test server, which the test breaks
/// as a network breaks: `cut()` resets every connection through it and refuses new ones, until
/// `restore()`. It also counts the connections Shello has open through it, to see one close, and
/// every one it opened, to see that none was made. ShelloCoreTests' FaultyProxy, of which this keeps
/// what the UI tests need.
final class FaultyProxy: Sendable {
    let port: UInt16
    private let listener: NWListener
    private let targetPort: UInt16
    private let queue = DispatchQueue(label: "ch.shello.uitests.proxy")
    private let state = Mutex<(isCut: Bool, connections: [NWConnection], open: Int, accepted: Int)>(
        (false, [], 0, 0))

    /// The connections Shello opened through the proxy and has not closed yet.
    var openConnectionCount: Int { state.withLock { $0.open } }

    /// Every connection Shello opened through the proxy.
    var acceptedConnectionCount: Int { state.withLock { $0.accepted } }

    /// Waits until Shello has closed every connection through the proxy, for at most `timeout`
    /// seconds, and returns whether it did.
    func waitUntilNoConnectionIsOpen(timeout: TimeInterval) -> Bool {
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in self?.openConnectionCount == 0 }, object: nil)
        return XCTWaiter.wait(for: [closed], timeout: timeout) == .completed
    }

    init(to targetPort: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        self.targetPort = targetPort
        let queue = queue
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
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
    }

    deinit {
        listener.cancel()
        for connection in state.withLock({ $0.connections }) {
            connection.forceCancel()
        }
    }

    func cut() {
        let connections = state.withLock { state in
            state.isCut = true
            state.open = 0
            defer { state.connections = [] }
            return state.connections
        }
        for connection in connections {
            connection.forceCancel()
        }
    }

    func restore() {
        state.withLock { $0.isCut = false }
    }

    private func accept(_ inbound: NWConnection) {
        guard !state.withLock({ $0.isCut }) else {
            inbound.forceCancel()
            return
        }
        let outbound = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: targetPort)!, using: .tcp)
        state.withLock { state in
            state.connections += [inbound, outbound]
            state.open += 1
            state.accepted += 1
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pipe(from: inbound, to: outbound, fromShello: true)
        pipe(from: outbound, to: inbound, fromShello: false)
    }

    /// Passes what `source` receives on to `destination`, then its end. The end of what Shello
    /// sends is its connection closing.
    private func pipe(from source: NWConnection, to destination: NWConnection, fromShello: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            let next: @Sendable (NWError?) -> Void = { [weak self] sendError in
                if isComplete || error != nil || sendError != nil {
                    if fromShello {
                        self?.state.withLock { $0.open = max(0, $0.open - 1) }
                    }
                    destination.send(
                        content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                } else {
                    self?.pipe(from: source, to: destination, fromShello: fromShello)
                }
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed(next))
            } else {
                next(nil)
            }
        }
    }
}
