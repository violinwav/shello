import XCTest
import notify

extension XCUIApplication {
    /// Launches Shello with an empty database and settings of its own, so that every test starts
    /// from no hosts. Debug builds only; see App/ShelloApp.swift.
    /// - Parameters:
    ///   - appearance: How the screens look, whatever the simulator's appearance. A test cannot
    ///     rely on `XCUIDevice.appearance`: CI's simulators stayed light with it set to dark.
    ///   - appLock: Whether app lock asks at launch and after its timeout. Off, Shello opens
    ///     unlocked, whatever the simulator's Face ID.
    ///   - environment: Further debug options of App/ShelloApp.swift.
    @MainActor
    static func launchWithEmptyDatabase(
        arguments: [String] = [], appearance: XCUIDevice.Appearance = .light, appLock: Bool = false,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHELLO_UI_TESTING"] = "1"
        app.launchEnvironment["SHELLO_UI_TESTING_APPEARANCE"] = appearance == .dark ? "dark" : "light"
        app.launchEnvironment["SHELLO_UI_TESTING_APP_LOCK"] = appLock ? "1" : "0"
        app.launchEnvironment.merge(environment) { _, option in option }
        app.launchArguments += arguments
        app.launch()
        return app
    }

    /// Checks from a screenshot that the screen is drawn in `appearance`, and attaches it: the
    /// design's dark ground is nearly black, its light ground nearly white.
    @MainActor
    func assertAppearance(_ appearance: XCUIDevice.Appearance, file: StaticString = #filePath, line: UInt = #line) {
        let screenshot = screenshot()
        XCTContext.runActivity(named: "The screen in \(appearance == .dark ? "dark" : "light") mode") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        let brightness = screenshot.image.averageBrightness
        if appearance == .dark {
            XCTAssertLessThan(brightness, 0.3, "The screen is not dark", file: file, line: line)
        } else {
            XCTAssertGreaterThan(brightness, 0.7, "The screen is not light", file: file, line: line)
        }
    }

    // MARK: - App lock

    /// The locked screen's title, which shows while app lock is engaged.
    @MainActor
    var lockedScreen: XCUIElement {
        staticTexts["Shello Is Locked"]
    }

    /// Shows the enrolled face to the Face ID prompt until Shello unlocks. The face only counts while
    /// the prompt looks for one, so it is shown again every second.
    @MainActor
    func unlockWithFaceID(file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date.now.addingTimeInterval(30)
        while lockedScreen.exists, Date.now < deadline {
            SimulatedFaceID.match()
            _ = lockedScreen.waitForNonExistence(timeout: 1)
        }
        XCTAssertFalse(lockedScreen.exists, "Face ID does not unlock Shello", file: file, line: line)
    }

    /// Ends the Face ID prompt without unlocking, as a user who changes their mind does: a face that
    /// does not match, then Cancel in LocalAuthentication's alert. Shello stays locked and offers
    /// Unlock.
    @MainActor
    func cancelFaceID(file: StaticString = #filePath, line: UInt = #line) {
        // The alert's button holds a button of the same name.
        let cancel = Self.springboard.buttons["com.apple.localauthentication.ax.authentication.button.cancel"]
            .firstMatch
        let deadline = Date.now.addingTimeInterval(30)
        while !cancel.exists, Date.now < deadline {
            SimulatedFaceID.failToMatch()
            _ = cancel.waitForExistence(timeout: 1)
        }
        cancel.tap()
        let unlock = buttons["Unlock"]
        XCTAssertTrue(
            unlock.wait(for: \.isEnabled, toEqual: true, timeout: 10), "Unlock stays disabled", file: file,
            line: line)
    }

    @MainActor
    static var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    /// `performAccessibilityAudit()`, less one false positive of its Dynamic Type check. The check
    /// reports some SwiftUI text whose font does scale as "partially unsupported", seemingly at random,
    /// because it looks for UIKit's `adjustsFontForContentSizeCategory`, which SwiftUI text does not
    /// expose (https://developer.apple.com/forums/thread/828525). Only static text is let through:
    /// controls, and text in a font that does not scale, which is reported as "unsupported", still
    /// fail. `testTextGrowsWithDynamicType` checks the scaling directly. Each ignored issue is
    /// attached to the test's results.
    @MainActor
    func auditAccessibility() throws {
        // The audit reads the screen as it is drawn: a push or a sheet still moving in shows up as
        // low contrast or clipped text, on a slow CI runner especially. Give it time to settle.
        settle(for: 2)
        defer { settleAfterAudit() }
        var ignored: [String] = []
        try performAccessibilityAudit { issue in
            let isFalsePositive =
                issue.auditType == .dynamicType
                && issue.compactDescription == "Dynamic Type font sizes are partially unsupported"
                && issue.element?.elementType == .staticText
            if isFalsePositive {
                ignored.append("\(issue.compactDescription): \(issue.element?.label ?? "?")")
            }
            return isFalsePositive
        }
        if !ignored.isEmpty {
            XCTContext.runActivity(named: "Ignored audit issues") { activity in
                activity.add(XCTAttachment(string: ignored.joined(separator: "\n")))
            }
        }
    }

    /// `performAccessibilityAudit()` while a system alert shows, without two checks that misreport
    /// the alert UIKit draws and would fail `auditAccessibility()` on it:
    /// - Dynamic Type: the alert scales its title, message and buttons, yet each of its labels is
    ///   reported as "partially unsupported", the buttons' on an element the audit cannot name.
    /// - Element detection: the import confirmation is reported as showing "potentially inaccessible
    ///   text" on an element the audit cannot name, although its title, message and buttons are all
    ///   elements.
    ///
    /// Contrast, hit regions, descriptions, clipped text and traits are still checked. The screen
    /// behind the alert gets the full audit before and after it.
    @MainActor
    func auditAlertAccessibility() throws {
        settle(for: 2)
        defer { settleAfterAudit() }
        try performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .elementDetection]))
    }

    /// Waits for moving views to come to rest, which XCUITest does not wait for in the system's file
    /// pickers, nor for an accessibility audit to finish.
    @MainActor
    func settle(for seconds: TimeInterval = 1) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "The screen settles")], timeout: seconds)
    }

    /// The audit makes the text larger while it runs and puts it back at the end. A tap while the
    /// screen lays out again can miss what it aims at.
    @MainActor
    private func settleAfterAudit() {
        settle(for: 1)
    }

    /// Fills in the host sheet's text fields that have a value here, and saves.
    @MainActor
    func addHost(name: String, address: String, port: String? = nil, user: String? = nil) {
        buttons["Add Host"].firstMatch.tap()
        enter(name, into: textFields["Name"])
        enter(address, into: textFields["Address"])
        if let port {
            replace(with: port, in: textFields["Port"])
        }
        if let user {
            enter(user, into: textFields["User"])
        }
        navigationBars["New Host"].buttons["Save"].tap()
        XCTAssertTrue(navigationBars["Hosts"].waitForExistence(timeout: 5))
    }

    @MainActor
    func enter(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    /// Scrolls down the screen, a little at a time, until `element` can be tapped. Lists create rows
    /// only as they scroll into view.
    @MainActor
    func reveal(_ element: XCUIElement) {
        var swiped = false
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            swipeUp(velocity: .slow)
            swiped = true
        }
        // A list glides on after a swipe, and a tap on a gliding list only stops it.
        if swiped { settle() }
        XCTAssertTrue(element.isHittable, "\(element) is not on screen")
    }

    /// The menu picker labelled `label`: a button that reads the label, then the chosen value, such
    /// as "Method, SSH Key".
    @MainActor
    func picker(_ label: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(label), ")).firstMatch
    }

    /// Chooses `option` in the menu of the picker labelled `label`.
    @MainActor
    func choose(_ option: String, in label: String) {
        let picker = picker(label)
        reveal(picker)
        picker.tap()
        let item = buttons[option]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
        XCTAssertEqual(picker.label, "\(label), \(option)")
    }

    /// Replaces a text field's value with `text`.
    @MainActor
    func replace(with text: String, in field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let length = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length) + text)
    }

    /// Adds `nas`, a favourite in the new group Homelab with the new tag Staging.
    @MainActor
    func addTaggedFavorite() {
        buttons["Add Host"].firstMatch.tap()
        // The switch comes first, before the keyboard has been up. In three CI runs, the tap on it
        // right after Return had put the keyboard away changed nothing, and the screen recordings
        // show no reaction at all. A tap in the middle of the switch's row can land on its label;
        // tap the switch itself.
        let favorite = switches["Favorite"].firstMatch
        reveal(favorite)
        favorite.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(favorite.value as? String, "1")

        enter("nas", into: textFields["Name"])
        enter("nas.lan", into: textFields["Address"])
        // Return in the last field of the section puts the keyboard away.
        enter("admin\n", into: textFields["User"])
        reveal(buttons["New Group…"])
        buttons["New Group…"].tap()
        enter("Homelab", into: alerts["New Group"].textFields.firstMatch)
        alerts["New Group"].buttons["Add"].tap()

        reveal(buttons["New Tag…"])
        buttons["New Tag…"].tap()
        // The keyboard can cover the colours: put it away, choose the colour, then type the name.
        textFields["Tag Name"].typeText("\n")
        buttons["Purple"].tap()
        XCTAssertTrue(buttons["Purple"].isSelected)
        enter("Staging", into: textFields["Tag Name"])
        navigationBars["New Tag"].buttons["Add"].tap()
        XCTAssertTrue(buttons["Staging"].waitForExistence(timeout: 5))
        XCTAssertTrue(buttons["Staging"].isSelected)

        navigationBars["New Host"].buttons["Save"].tap()
        XCTAssertTrue(buttons["nas"].firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: - Files

    /// The system's file exporter or importer, once it shows.
    @MainActor
    var filePicker: XCUIElement {
        filePickerBars.firstMatch
    }

    /// The bars of the file picker's screens. A folder's screen is pushed onto the list of
    /// locations, so there can be more than one.
    @MainActor
    private var filePickerBars: XCUIElementQuery {
        navigationBars.matching(identifier: "FullDocumentManagerViewControllerNavigationBar")
    }

    /// Taps Export Data in the open Settings sheet and saves the file in On My iPhone under the name
    /// the app suggests, which has the time in it. Returns the file's name as the app's result line
    /// gives it: the exporter's name field is not always in the accessibility tree.
    @MainActor
    func exportData() -> String {
        buttons["Export Data…"].tap()
        showOnMyIPhone()
        // Save is enabled once the picker has opened the folder, which takes a while on a slow runner.
        // It is the enabled one of the bars' Save buttons.
        let save = filePickerBars.buttons
            .matching(NSPredicate(format: "label == %@ AND isEnabled == true", "Save")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 30), "Save stays disabled")
        save.tap()
        XCTAssertTrue(filePicker.waitForNonExistence(timeout: 30))
        // "Exported 1 host to “Shello Export 2026-10-21 14.05.09.json”."
        let result = staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Exported ")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        guard let name = result.label.firstMatch(of: /“(.+)”/)?.1 else {
            XCTFail("\(result.label) does not name the file")
            return ""
        }
        return String(name)
    }

    /// Taps Import Data in the open Settings sheet and picks the file `name` in On My iPhone.
    @MainActor
    func importData(named name: String) {
        showImporterOnMyIPhone()
        // A picked file closes the importer at once, once Files knows it (see
        // `prepareFilesForPicking()`). A file the importer still shows is tapped again every ten
        // seconds, for up to three minutes.
        let deadline = Date.now.addingTimeInterval(180)
        repeat {
            if pickOnce(named: name) { return }
        } while Date.now < deadline && cells.containing(.staticText, identifier: name).firstMatch.exists
        XCTFail("The file importer does not pick \(name)")
    }

    /// Makes sure that the importer can pick what the exporter saves in On My iPhone. A new
    /// simulator, which CI starts each run with, does not allow that for minutes: until Files' first
    /// indexing pass, picking a file there does nothing at all. The importer stays, and the app logs
    /// "Could not resolve bookmark … The file doesn’t exist." On a Mac the pass came one to three
    /// minutes after the first file was saved, while the importer kept trying. In CI it came only
    /// once Shello had left the screen: an importer kept open for ten minutes never picked its file,
    /// while the next test's file, a minute after Shello closed, was picked at once.
    ///
    /// So this saves an empty export and tries to import it. As long as the importer cannot pick it,
    /// it closes Shello, waits half a minute and tries again in a new launch. A simulator whose
    /// On My iPhone is already indexed picks the file at once.
    @MainActor
    static func prepareFilesForPicking() {
        var app = launchWithEmptyDatabase()
        app.buttons["Settings"].tap()
        let name = app.exportData()
        for _ in 0..<12 {
            app.showImporterOnMyIPhone()
            if app.pickOnce(named: name) {
                let alert = app.alerts["Nothing to Import"]
                XCTAssertTrue(alert.waitForExistence(timeout: 10))
                alert.buttons["OK"].tap()
                app.terminate()
                return
            }
            app.terminate()
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "Files indexes On My iPhone")], timeout: 30)
            app = launchWithEmptyDatabase()
            app.buttons["Settings"].tap()
        }
        XCTFail("The file importer never picks \(name)")
    }

    /// Opens the file importer on On My iPhone from the open Settings sheet.
    @MainActor
    private func showImporterOnMyIPhone() {
        buttons["Import Data…"].tap()
        // The importer opens on the recent files; the exporter's files are under Browse.
        let browse = tabBars["DOC.browsingModeTabBar"].buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 30))
        browse.tap()
        showOnMyIPhone()
    }

    /// Taps the file `name` in the open importer, and returns whether the importer picked it.
    @MainActor
    private func pickOnce(named name: String) -> Bool {
        let file = cells.containing(.staticText, identifier: name).firstMatch
        // The file's icon, at the top of its cell.
        let icon = CGVector(dx: 0.5, dy: 0.25)
        scrollClearOfTheBars(file, at: icon)
        file.coordinate(withNormalizedOffset: icon).tap()
        return filePicker.waitForNonExistence(timeout: 10)
    }

    /// Scrolls the file picker until the point `offset` of `file` lies between the picker's bars,
    /// which the files scroll under: a tap there would otherwise land on the search field or a tab.
    /// Files are sorted by name, so a new export comes after the earlier ones, and the picker makes
    /// cells only as they scroll into view. While the file has no cell yet, a flick passes many files
    /// at once, however many earlier runs left. Then each drag starts at once, since holding a file
    /// first picks it up to move it, and holds still at its end, so that the list stops at once: a
    /// tap on a gliding list only stops it.
    @MainActor
    private func scrollClearOfTheBars(_ file: XCUIElement, at offset: CGVector) {
        let clear = (filePicker.frame.maxY + 20)...(tabBars["DOC.browsingModeTabBar"].frame.minY - 20)
        for _ in 0..<40 {
            let point = file.exists ? file.frame.minY + file.frame.height * offset.dy : nil
            if let point, clear.contains(point) { return }
            guard let point else {
                swipeUp(velocity: .fast)
                settle(for: 2)
                continue
            }
            // A drag up brings later files into view, a drag down earlier ones.
            let (start, distance): (CGFloat, CGFloat) = point < clear.lowerBound ? (0.45, 200) : (0.75, -200)
            let from = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
            from.press(
                forDuration: 0, thenDragTo: from.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow,
                thenHoldForDuration: 0.3)
        }
        XCTFail("\(file) does not come clear of the file picker's bars")
    }

    /// Moves the file picker to On My iPhone, the simulator's own files: every test run can write
    /// there, signed in to iCloud or not.
    @MainActor
    private func showOnMyIPhone() {
        // The picker can take more than ten seconds to show while a new simulator is still busy.
        XCTAssertTrue(filePicker.waitForExistence(timeout: 30))
        // The title is text, or a button for the folder's menu, "On My iPhone, Actions Menu".
        let title = filePickerBars.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "On My iPhone")).firstMatch
        if !title.waitForExistence(timeout: 2) {
            let location = cells["DOC.sidebar.item.On My iPhone"]
            // In a folder, the back button leads to the list of locations.
            if !location.exists {
                filePicker.buttons["BackButton"].tap()
            }
            XCTAssertTrue(location.waitForExistence(timeout: 10))
            location.tap()
            XCTAssertTrue(title.waitForExistence(timeout: 10))
        }
        // Let the folder's screen come to rest before the next tap.
        settle()
    }
}

extension UIImage {
    /// The image's mean brightness, from 0 for black to 1 for white.
    var averageBrightness: CGFloat {
        guard let image = cgImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.interpolationQuality = .medium
            context?.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return CGFloat(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }
}

/// Face ID in the simulator, driven through the notifications that its simulated biometry listens
/// to, as the simulator's Features menu does.
enum SimulatedFaceID {
    /// Enrols a face, so that LocalAuthentication can ask for Face ID.
    static func enroll() {
        setEnrolled(true)
    }

    /// Removes the face, as a new simulator has none.
    static func unenroll() {
        setEnrolled(false)
    }

    /// The face in front of the camera matches.
    static func match() {
        notify_post("com.apple.BiometricKit_Sim.pearl.match")
    }

    /// The face in front of the camera does not match.
    static func failToMatch() {
        notify_post("com.apple.BiometricKit_Sim.pearl.nomatch")
    }

    private static func setEnrolled(_ isEnrolled: Bool) {
        var token: Int32 = 0
        notify_register_check("com.apple.BiometricKit.enrollmentChanged", &token)
        notify_set_state(token, isEnrolled ? 1 : 0)
        notify_post("com.apple.BiometricKit.enrollmentChanged")
        notify_cancel(token)
    }
}
