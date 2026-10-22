import CryptoKit
import Darwin
import XCTest

/// Connecting to a host (README sections 3 and 4) against the test servers of TestServers/README.md:
/// the trust sheet on the first connection, the block on a changed host key and its replacement,
/// sign-in with a password, an SSH key or keyboard-interactive that opens the shell, with its key
/// exchange marked post-quantum or classical (README section 14), and the Local Network explanation,
/// each screen audited. Skipped when the server is not running; the password and keyboard-interactive
/// sign-ins also when the server takes keys only, as CI's does.
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
    /// and the sheet shows both keys. Closing it closes the terminal too. Replacing the trusted key
    /// (README section 3) takes a confirmation, then Face ID, and connects again: past the host key
    /// now, the password, never sent before, is refused.
    @MainActor
    func testChangedHostKeyBlocksTheConnectionUntilItIsReplaced() throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        SimulatedFaceID.enroll()
        addTeardownBlock { SimulatedFaceID.unenroll() }
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

        app.buttons["Connect"].tap()
        XCTAssertTrue(blockSheet.waitForExistence(timeout: 15))
        let replace = app.buttons["Replace Trusted Key…"]
        app.reveal(replace)
        replace.tap()
        let confirm = app.buttons["Replace Key"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        try app.auditAlertAccessibility()
        confirm.tap()
        app.confirmWithFaceID(until: blockSheet)

        XCTAssertTrue(app.connectionStatus(containing: "didn’t accept").waitForExistence(timeout: 15))
        app.navigationBars[TestServer.hostName].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }

    /// Signing in with an SSH key through Shello's SSH agent (STACK section 7.3): the host editor
    /// chooses the test server's client key, which this launch keeps in memory, and Connect signs in
    /// with it. CI's sshd takes the key, so this runs there too.
    @MainActor
    func testSSHKeySignInOpensTheShell() throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        let app = XCUIApplication.launchWithEmptyDatabase(
            environment: ["SHELLO_UI_TESTING_SSH_KEY": TestServer.clientKeyLaunchValue])
        app.addKeyHost()

        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()
        XCTAssertTrue(app.connectionStatus(containing: "Connecting").waitForNonExistence(timeout: 15))
        XCTAssertFalse(app.connectionStatus(containing: "didn’t").exists)
        // The Connection button shows once the shell is attached.
        app.openConnectionSheet(marked: "Post-Quantum Key Exchange")
        app.navigationBars["Connection"].buttons["Close"].tap()

        app.navigationBars[TestServer.hostName].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }

    /// Keyboard-interactive sign-in (README section 4): the Docker server asks `shello-otp` for its
    /// password, an answer it hides, then for a one-time code, which it shows, each in a round of
    /// its own in the one sign-in sheet. Both rounds are audited. CI's sshd asks no questions.
    @MainActor
    func testKeyboardInteractiveAsksThePasswordThenTheOneTimeCode() throws {
        try XCTSkipUnless(TestServer.isRunning, TestServer.notRunning)
        guard let password = TestServer.password else { throw XCTSkip("The test server asks no questions.") }
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addKeyboardInteractiveHost(user: "shello-otp")

        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()

        let signIn = app.navigationBars["Sign In"]
        let passwordField = app.secureTextFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15))
        XCTAssertTrue(signIn.exists)
        app.putKeyboardAway()
        try app.auditAccessibility()
        app.enter(password, into: passwordField)
        signIn.buttons["Sign In"].tap()

        // The answer shows as it is typed: an ordinary text field.
        let codeField = app.textFields["Verification code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15))
        app.putKeyboardAway()
        try app.auditAccessibility()
        // Return in the last field signs in.
        app.enter(TestServer.oneTimeCode() + "\n", into: codeField)

        XCTAssertTrue(signIn.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.waitForTerminalText("Shello test server"))
        app.navigationBars[TestServer.hostName].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }

    /// Before the first connection to a server on the local network, Shello explains iOS's Local
    /// Network question (README section 3, TN3179). Not Now goes back, and the next Connect explains
    /// again; once the user continues, the terminal opens, and later connections explain nothing.
    /// The simulator has no Local Network question of its own, so the server need not exist.
    @MainActor
    func testLocalNetworkIsExplainedBeforeTheFirstLocalConnection() throws {
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addPasswordHost(password: "never-sent", address: "192.168.255.254", port: 22)

        app.buttons["Connect"].tap()
        let explanation = app.navigationBars["Local Network"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["192.168.255.254 is on your local network."].exists)
        try app.auditAccessibility()
        explanation.buttons["Not Now"].tap()
        XCTAssertTrue(explanation.waitForNonExistence(timeout: 5))

        app.buttons["Connect"].tap()
        XCTAssertTrue(explanation.waitForExistence(timeout: 10))
        explanation.buttons["Continue"].tap()
        let terminal = app.navigationBars[TestServer.hostName]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.buttons["Close"].tap()

        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
        app.buttons["Connect"].tap()
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertFalse(explanation.exists)
        terminal.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }

    /// The whole way, with the password: trust, sign in, and the shell in the terminal. OpenSSH 10
    /// negotiates mlkem768x25519-sha256, which the Connection button and its sheet mark post-quantum.
    /// What the keyboard types runs on the server: `uname` prints the server's kernel, and `exit`
    /// ends the connection.
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

        app.openConnectionSheet(marked: "Post-Quantum Key Exchange")
        XCTAssertEqual(app.keyExchangeAlgorithm.value as? String, "mlkem768x25519-sha256")
        try app.auditAccessibility()
        // Command-W closes the sheet, not the terminal behind it. The simulator drops the first key
        // from a hardware keyboard after the on-screen keyboard typed, here the search: Shift goes
        // first (TerminalTests).
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Connection"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[TestServer.hostName].exists)

        app.terminal.tap()
        XCTAssertTrue(app.keys["u"].waitForExistence(timeout: 10))
        for key in ["u", "n", "a", "m", "e", "Return"] {
            app.keys[key].tap()
        }
        XCTAssertTrue(app.waitForTerminalText("Linux"))

        // The connection ends with the shell, and the Connection button goes with it.
        app.terminal.tap()
        XCTAssertTrue(app.keys["e"].waitForExistence(timeout: 10))
        for key in ["e", "x", "i", "t", "Return"] {
            app.keys[key].tap()
        }
        XCTAssertTrue(app.connectionStatus(containing: "Connection closed").waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars[TestServer.hostName].buttons["Connection"].exists)

        app.navigationBars[TestServer.hostName].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }

    /// The test server without post-quantum key exchange negotiates curve25519-sha256, which the
    /// Connection button and its sheet, opened with Command-I, mark classical. The sheet's audit is
    /// the one above.
    @MainActor
    func testClassicalKeyExchangeIsMarkedClassical() throws {
        try XCTSkipUnless(TestServer.isClassicalRunning, TestServer.classicalNotRunning)
        guard let password = TestServer.password else { throw XCTSkip("The test server takes keys only.") }
        let app = XCUIApplication.launchWithEmptyDatabase()
        app.addPasswordHost(password: password, port: TestServer.classicalPort)

        app.buttons["Connect"].tap()
        let trustSheet = app.navigationBars["Trust This Server?"]
        XCTAssertTrue(trustSheet.waitForExistence(timeout: 15))
        trustSheet.buttons["Trust"].tap()
        XCTAssertTrue(app.connectionStatus(containing: "Connecting").waitForNonExistence(timeout: 15))

        app.openConnectionSheet(marked: "Classical Key Exchange", withShortcut: true)
        XCTAssertEqual(app.keyExchangeAlgorithm.value as? String, "curve25519-sha256")
        app.navigationBars["Connection"].buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Connection"].waitForNonExistence(timeout: 5))
        app.navigationBars[TestServer.hostName].buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 10))
    }
}

/// The test server of TestServers/README.md on localhost port 2222: in Docker, user `shello` with a
/// password; or this Mac's own sshd, as in CI, keys only, as the user `SHELLO_TEST_SERVER_USER`
/// names, which xcodebuild passes on from `TEST_RUNNER_SHELLO_TEST_SERVER_USER`. Both serve host
/// key a; every credential is a public test fixture. Port 2224 has the same server with post-quantum
/// key exchange off.
enum TestServer {
    static let hostName = "test-server"
    /// Connecting by name, as Shello does.
    static let address = "localhost"
    static let port = 2222
    static let classicalPort = 2224

    private static let localUser = ProcessInfo.processInfo.environment["SHELLO_TEST_SERVER_USER"]
        .flatMap { $0.isEmpty ? nil : $0 }
    static let user = localUser ?? "shello"
    /// The user's password, or nil on a server that takes keys only.
    static let password: String? = localUser == nil ? "shello-test-password" : nil

    static let notRunning =
        "The test server is not running on localhost:2222. Start it with TestServers/ssh-server.sh (TestServers/README.md)."
    static let classicalNotRunning =
        "The test server without post-quantum key exchange is not running on localhost:2224. Start it with TestServers/ssh-server.sh (TestServers/README.md)."

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

    static let isRunning = hasSSHBanner(port: port)
    static let isClassicalRunning = hasSSHBanner(port: classicalPort)

    /// TestServers/keys/client_ed25519, which both servers let the test user in with, for the
    /// launch option that keeps it among the SSH keys in memory: its private key's 32 bytes in
    /// base64, then its name. A public test fixture.
    static let clientKeyLaunchValue = "ofQMdaZY6428Z0L+p1ROfYPD5L/UDl+PviWmLJf/bNY= shello-test-client"

    /// The Docker server's one-time code for `shello-otp` now (TestServers/openssh/google_authenticator):
    /// TOTP (RFC 6238), six digits, a new one every 30 seconds, from the fixture secret
    /// SHELLOTESTSECRET. SHA-1 is TOTP's, not SSH's.
    static func oneTimeCode() -> String {
        let secret = SymmetricKey(data: [145, 200, 181, 186, 100, 148, 228, 65, 68, 147] as [UInt8])
        let step = UInt64(Date.now.timeIntervalSince1970 / 30)
        let counter = Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: step >> ($0 * 8)) })
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: counter, using: secret))
        let offset = Int(mac[19] & 0x0f)
        let number = mac[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & 0x7fff_ffff
        let digits = String(number % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// Whether an SSH server greets on `port` of 127.0.0.1 within two seconds.
    private static func hasSSHBanner(port: Int) -> Bool {
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
    }
}

extension XCUIApplication {
    /// Adds the host `test-server` for the test server on `port`, signing in with `password`, and
    /// opens its details. The method and the password go first: while the keyboard is up, a tap on
    /// the picker only ends the typing (HostTests).
    @MainActor
    func addPasswordHost(password: String, address: String = TestServer.address, port: Int = TestServer.port) {
        buttons["Add Host"].firstMatch.tap()
        choose("Password", in: "Method")
        enter(password + "\n", into: secureTextFields["Password"])
        XCTAssertTrue(keyboards.firstMatch.waitForNonExistence(timeout: 10))
        saveAndOpenTestServerHost(address: address, port: port, user: TestServer.user)
    }

    /// Adds the host `test-server` for the test server, signing in with the SSH key
    /// `shello-test-client`, which the launch option `SHELLO_UI_TESTING_SSH_KEY` keeps in memory, and
    /// opens its details. SSH Key is a new host's method; the key goes first, before the keyboard is
    /// up.
    @MainActor
    func addKeyHost() {
        buttons["Add Host"].firstMatch.tap()
        let sshKey = picker("SSH Key")
        reveal(sshKey)
        sshKey.tap()
        XCTAssertTrue(navigationBars["SSH Key"].waitForExistence(timeout: 5))
        buttons["shello-test-client"].tap()
        XCTAssertTrue(navigationBars["New Host"].waitForExistence(timeout: 5))
        XCTAssertEqual(picker("SSH Key").label, "SSH Key, shello-test-client")
        saveAndOpenTestServerHost(address: TestServer.address, port: TestServer.port, user: TestServer.user)
    }

    /// Adds the host `test-server` for the test server as `user`, signing in with keyboard-interactive,
    /// and opens its details.
    @MainActor
    func addKeyboardInteractiveHost(user: String) {
        buttons["Add Host"].firstMatch.tap()
        choose("Keyboard-Interactive", in: "Method")
        saveAndOpenTestServerHost(address: TestServer.address, port: TestServer.port, user: user)
    }

    /// Fills in the open host editor's name `test-server`, `address`, `port` and `user`, saves, and
    /// opens the host's details.
    @MainActor
    private func saveAndOpenTestServerHost(address: String, port: Int, user: String) {
        enter(TestServer.hostName, into: textFields["Name"])
        enter(address, into: textFields["Address"])
        replace(with: String(port), in: textFields["Port"])
        enter(user, into: textFields["User"])
        navigationBars["New Host"].buttons["Save"].tap()
        let row = buttons[TestServer.hostName].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(navigationBars[TestServer.hostName].waitForExistence(timeout: 5))
    }

    /// Puts the keyboard away by dragging the sheet's list down, as a user does, and waits until it
    /// has gone and the screen has come to rest: an accessibility audit misreads a screen while the
    /// keyboard is up.
    @MainActor
    func putKeyboardAway(file: StaticString = #filePath, line: UInt = #line) {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(
            forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)), withVelocity: .slow,
            thenHoldForDuration: 0.3)
        XCTAssertTrue(
            keyboards.firstMatch.waitForNonExistence(timeout: 10), "The keyboard stays up", file: file, line: line)
        settle()
    }

    /// Shows the enrolled face to the Face ID prompt until `element` goes, as the confirmation
    /// makes it: the face only counts while the prompt looks for one, so it is shown every second.
    @MainActor
    func confirmWithFaceID(until element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date.now.addingTimeInterval(30)
        while element.exists, Date.now < deadline {
            SimulatedFaceID.match()
            _ = element.waitForNonExistence(timeout: 1)
        }
        XCTAssertFalse(element.exists, "Face ID does not confirm", file: file, line: line)
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

    /// Opens the connection sheet with the terminal's Connection button, or its shortcut Command-I.
    /// The button tells VoiceOver that the key exchange is `marking`, as the sheet then says.
    @MainActor
    func openConnectionSheet(
        marked marking: String, withShortcut: Bool = false, file: StaticString = #filePath, line: UInt = #line
    ) {
        let button = navigationBars[TestServer.hostName].buttons["Connection"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), file: file, line: line)
        XCTAssertEqual(button.value as? String, marking, file: file, line: line)
        if withShortcut {
            // The simulator drops the first key from a hardware keyboard after the on-screen
            // keyboard typed: Shift goes first (TerminalTests).
            typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
            typeKey("i", modifierFlags: .command)
        } else {
            button.tap()
        }
        XCTAssertTrue(navigationBars["Connection"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(staticTexts[marking].exists, file: file, line: line)
    }

    /// The key exchange's name on the connection sheet.
    @MainActor
    var keyExchangeAlgorithm: XCUIElement {
        descendants(matching: .any).matching(identifier: "key-exchange").firstMatch
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
