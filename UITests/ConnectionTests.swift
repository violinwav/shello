import Darwin
import XCTest

/// Connecting to a host (README sections 3 and 4) against the test server of TestServers/README.md:
/// the trust sheet on the first connection, the block on a changed host key, and a password sign-in
/// that opens the shell, each screen audited. Skipped when the server is not running; the sign-in
/// also when the server takes keys only, as CI's does.
final class ConnectionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The first connection asks to trust the host key, with its type and fingerprint; Cancel closes
    /// the terminal and trusts nothing, so the next connection asks again. Once trusted, a connection
    /// asks nothing. A password the server refuses fails the sign-in, which the terminal screen says.
    @MainActor
    func testFirstConnectionAsksToTrustTheHostKey() throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addPasswordHost(password: "not-the-password")

        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))

        app.buttons["Connect"].tap()
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        let fingerprint = app.fingerprints.firstMatch
        XCTAssertEqual(fingerprint.label, "Fingerprint")
        XCTAssertEqual(fingerprint.value as? String, TestServer.hostKeyA.spokenFingerprint)
        let keyType = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "ED25519", "ED25519"))
        XCTAssertTrue(keyType.firstMatch.exists)
        try app.auditAccessibility()
        trustSheet.buttons["Trust"].tap()

        let refused = app.connectionStatus(containing: "didn’t accept")
        XCTAssertTrue(refused.waitForExistence(timeout: 15))
        try app.auditAccessibility()
        app.navigationBars[TestServer.hostName].buttons["Close"].tap()

        // Trusted now: the second connection goes straight to signing in.
        app.buttons["Connect"].tap()
        XCTAssertTrue(refused.waitForExistence(timeout: 15))
        XCTAssertFalse(trustSheet.exists)
        app.navigationBars[TestServer.hostName].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 5))
    }

    /// Another key is trusted for the server than the one it presents: the connection is blocked,
    /// and the sheet shows both keys. Closing it closes the terminal too.
    @MainActor
    func testChangedHostKeyBlocksTheConnection() throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        let keyB = TestServer.hostKeyB
        let app = XCUIApplication.launchWithEmptyDatabase(
            appearance: .dark,
            environment: [
                "SHELLO_UI_TESTING_TRUSTED_HOST_KEY":
                    "\(TestServer.address) \(TestServer.port) \(keyB.algorithm) \(keyB.base64) \(keyB.fingerprint)"
            ])
        app.addPasswordHost(password: "never-sent")

        app.buttons["Connect"].tap()
        let blockSheet = app.navigationBars["Host Key Changed"]
        XCTAssertTrue(blockSheet.waitForExistence(timeout: 15))
        XCTAssertEqual(app.fingerprints.element(boundBy: 0).label, "Trusted Key, Fingerprint")
        XCTAssertEqual(app.fingerprints.element(boundBy: 0).value as? String, keyB.spokenFingerprint)
        XCTAssertEqual(app.fingerprints.element(boundBy: 1).label, "Key Presented Now, Fingerprint")
        XCTAssertEqual(app.fingerprints.element(boundBy: 1).value as? String, TestServer.hostKeyA.spokenFingerprint)
        try app.auditAccessibility()

        blockSheet.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars[TestServer.hostName].buttons["Close"].exists)
    }

    /// The whole way, with the password: trust, sign in, and the shell in the terminal. What the
    /// keyboard types runs on the server: `uname` prints the server's kernel.
    @MainActor
    func testPasswordSignInOpensTheShell() throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        guard let password = TestServer.password else { throw XCTSkip("The test server takes keys only.") }
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addPasswordHost(password: password)

        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()
        XCTAssertTrue(app.connectionStatus(containing: "Connecting").waitForNonExistence(timeout: 15))
        // The server's message of the day, the shell's first line.
        XCTAssertTrue(app.waitForTerminalText("Shello test server"))
        try app.auditAccessibility()

        app.terminal.tap()
        XCTAssertTrue(app.keys["u"].waitForExistence(timeout: 10))
        for key in ["u", "n", "a", "m", "e", "Return"] {
            app.keys[key].tap()
        }
        XCTAssertTrue(app.waitForTerminalText("Linux"))

        app.navigationBars[TestServer.hostName].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }
}

/// The test server of TestServers/README.md on localhost port 2222: in Docker, user `shello` with a
/// password; or this Mac's own sshd, as in CI, keys only, as the user `SHELLO_TEST_SERVER_USER`
/// names, which xcodebuild passes on from `TEST_RUNNER_SHELLO_TEST_SERVER_USER`. Both serve host
/// key a; every credential is a public test fixture.
enum TestServer {
    static let hostName = "test-server"
    /// Connecting by name, as Shello does.
    static let address = "localhost"
    static let port = 2222

    private static let localUser = ProcessInfo.processInfo.environment["SHELLO_TEST_SERVER_USER"]
        .flatMap { $0.isEmpty ? nil : $0 }
    static let user = localUser ?? "shello"
    /// The user's password, or nil on a server that takes keys only.
    static let password: String? = localUser == nil ? "shello-test-password" : nil

    static let notRunning =
        "The test server is not running on localhost:2222. Start it with TestServers/ssh-server.sh (TestServers/README.md)."

    struct Key {
        let algorithm: String
        let base64: String
        let fingerprint: String

        /// The fingerprint as the sheets give it to VoiceOver: "SHA-256", then the hash four
        /// characters at a time.
        var spokenFingerprint: String {
            let hash = Array(fingerprint.dropFirst("SHA256:".count))
            let groups = stride(from: 0, to: hash.count, by: 4).map { String(hash[$0..<min($0 + 4, hash.count)]) }
            return "SHA-256, " + groups.joined(separator: ", ")
        }
    }

    /// TestServers/keys/ssh_host_ed25519_key_a.pub, which the server presents.
    static let hostKeyA = Key(
        algorithm: "ssh-ed25519", base64: "AAAAC3NzaC1lZDI1NTE5AAAAIHgTJMsflS9c2SZNLqrNUxilEPdrI1trFCrvwBsv0BQ9",
        fingerprint: "SHA256:lgFemmffoQcpnsIrUqaSgDH/p2JSkANqAb3Qm8/avRY")

    /// TestServers/keys/ssh_host_ed25519_key_b.pub.
    static let hostKeyB = Key(
        algorithm: "ssh-ed25519", base64: "AAAAC3NzaC1lZDI1NTE5AAAAIIJJGCfEG93QAyNvR5/qMneE615D5dVdNz8eF8nfUV2G",
        fingerprint: "SHA256:vRTlNPuThVvvrnjbeKgZ/H5Ud52Nq2MKVToLDK4pofI")

    /// Whether an SSH server greets on 127.0.0.1:2222 within two seconds.
    static let isRunning: Bool = {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return false }
        var banner = [UInt8](repeating: 0, count: 8)
        return recv(socket, &banner, banner.count, MSG_WAITALL) == banner.count
            && String(decoding: banner, as: UTF8.self) == "SSH-2.0-"
    }()
}

extension XCUIApplication {
    /// Adds the host `test-server` for the test server, signing in with `password`, and opens its
    /// details. The method and the password go first: while the keyboard is up, a tap on the picker
    /// only ends the typing (HostTests).
    @MainActor
    func addPasswordHost(password: String) {
        buttons["Add Host"].firstMatch.tap()
        choose("Password", in: "Method")
        enter(password + "\n", into: secureTextFields["Password"])
        XCTAssertTrue(keyboards.firstMatch.waitForNonExistence(timeout: 10))
        enter(TestServer.hostName, into: textFields["Name"])
        enter(TestServer.address, into: textFields["Address"])
        replace(with: String(TestServer.port), in: textFields["Port"])
        enter(TestServer.user, into: textFields["User"])
        navigationBars["New Host"].buttons["Save"].tap()
        let row = buttons[TestServer.hostName].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(navigationBars[TestServer.hostName].waitForExistence(timeout: 5))
    }

    /// The host key fingerprints on a sheet, in their order.
    @MainActor
    var fingerprints: XCUIElementQuery {
        descendants(matching: .any).matching(identifier: "fingerprint")
    }

    /// The status above a host's terminal, while it says `text`.
    @MainActor
    func connectionStatus(containing text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Searches the terminal for `text`, once a second until it is there once, for up to `timeout`:
    /// the server's output arrives when it does, and the terminal's text is not in the accessibility
    /// tree (TerminalTests).
    @MainActor
    func waitForTerminalText(_ text: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            search(for: text)
            let found = staticTexts["1 of 1"].waitForExistence(timeout: 1)
            buttons["Done"].tap()
            if found { return true }
        } while Date.now < deadline
        return false
    }
}
