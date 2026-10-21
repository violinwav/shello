import XCTest

extension XCUIApplication {
    /// Launches Shello with an empty database of its own, so that every test starts from no hosts.
    /// Debug builds only; see App/ShelloApp.swift.
    @MainActor
    static func launchWithEmptyDatabase(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHELLO_UI_TESTING"] = "1"
        app.launchArguments += arguments
        app.launch()
        return app
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
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "The screen settles")], timeout: 1)
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
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "The alert settles")], timeout: 1)
        try performAccessibilityAudit(
            for: XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .elementDetection]))
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
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable, "\(element) is not on screen")
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
        enter("nas", into: textFields["Name"])
        enter("nas.lan", into: textFields["Address"])
        // Return in the last field of the section puts the keyboard away.
        enter("admin\n", into: textFields["User"])

        // A tap in the middle of a switch's row can land on its label; tap the switch itself.
        let favorite = switches["Favorite"].firstMatch
        reveal(favorite)
        favorite.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(favorite.value as? String, "1")
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
        navigationBars["FullDocumentManagerViewControllerNavigationBar"]
    }

    /// Taps Export Data in the open Settings sheet and saves the file in On My iPhone under the name
    /// the app suggests, which has the time in it. Returns the file's name.
    @MainActor
    func exportData() -> String {
        buttons["Export Data…"].tap()
        showOnMyIPhone()
        let nameField = textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        let name = nameField.value as? String ?? ""
        // Save is enabled once the picker has opened the folder.
        let save = filePicker.buttons["Save"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "Save stays disabled")
        save.tap()
        XCTAssertTrue(filePicker.waitForNonExistence(timeout: 10))
        return name.hasSuffix(".json") ? name : "\(name).json"
    }

    /// Taps Import Data in the open Settings sheet and picks the file `name` in On My iPhone.
    @MainActor
    func importData(named name: String) {
        buttons["Import Data…"].tap()
        // The importer opens on the recent files; the exporter's files are under Browse.
        let browse = tabBars["DOC.browsingModeTabBar"].buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        browse.tap()
        showOnMyIPhone()
        let file = cells.containing(.staticText, identifier: name).firstMatch
        // The file's icon, at the top of its cell.
        let icon = CGVector(dx: 0.5, dy: 0.25)
        scrollClearOfTheBars(file, at: icon)
        file.coordinate(withNormalizedOffset: icon).tap()
        XCTAssertTrue(filePicker.waitForNonExistence(timeout: 10))
    }

    /// Scrolls the file picker until the point `offset` of `file` lies between the picker's bars,
    /// which the files scroll under: a tap there would otherwise land on the search field or a tab.
    /// Files are sorted by name, so a new export comes after the earlier ones, and the picker makes
    /// cells only as they scroll into view. Each drag starts at once, since holding a file first
    /// picks it up to move it, and holds still at its end, so that the list stops at once: a tap on a
    /// gliding list only stops it.
    @MainActor
    private func scrollClearOfTheBars(_ file: XCUIElement, at offset: CGVector) {
        let clear = (filePicker.frame.maxY + 20)...(tabBars["DOC.browsingModeTabBar"].frame.minY - 20)
        for _ in 0..<40 {
            let point = file.exists ? file.frame.minY + file.frame.height * offset.dy : nil
            if let point, clear.contains(point) { return }
            // A drag up brings later files into view, a long one while the file has no cell yet; a
            // drag down brings back earlier ones.
            let (start, distance): (CGFloat, CGFloat) =
                switch point {
                case nil: (0.75, -0.4 * frame.height)
                case let point? where point < clear.lowerBound: (0.45, 200)
                default: (0.75, -200)
                }
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
        XCTAssertTrue(filePicker.waitForExistence(timeout: 10))
        // The title is text, or a button for the folder's menu, "On My iPhone, Actions Menu".
        let title = filePicker.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "On My iPhone")).firstMatch
        guard !title.waitForExistence(timeout: 2) else { return }
        let location = cells["DOC.sidebar.item.On My iPhone"]
        // In a folder, the back button leads to the list of locations.
        if !location.exists {
            filePicker.buttons["BackButton"].tap()
        }
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        location.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
    }
}
