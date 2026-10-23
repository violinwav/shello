import ShelloModel
import SwiftTerm
import Testing
import UIKit

@testable import ShelloTerminalUI

/// The terminal and its byte stream (README section 5): output is drawn, input and sizes go to the
/// stream, and the terminal behaves as xterm does. Each test puts the terminal in a window, where
/// SwiftTerm draws and resizes.
@MainActor
@Suite(.serialized) struct TerminalControllerTests {
    @Test func feedsOutputAndReportsItsSizeOnAttach() async {
        let fixture = TerminalFixture()
        #expect(await fixture.settle())
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        #expect(stream.sizes == [fixture.controller.size])
        stream.write("hello\r\nworld")
        #expect(await fixture.wait { fixture.screen.prefix(2) == ["hello", "world"] })
        #expect(fixture.controller.streamState == .attached)
    }

    @Test func sendsTypingToTheStream() async {
        let fixture = TerminalFixture()
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        fixture.view.insertText("ls -la")
        fixture.view.insertText("\n")
        // Return is a carriage return, as a terminal sends it.
        #expect(stream.sentText == "ls -la\r")
    }

    /// The grid follows the view's size and the font size, and each new size reaches the stream
    /// (README section 5: rotation, split view and font size change).
    @Test func reportsNewSizes() async {
        let fixture = TerminalFixture(size: CGSize(width: 390, height: 400))
        let stream = RecordingStream()
        #expect(await fixture.settle())
        fixture.controller.attach(stream)
        let narrow = fixture.controller.size

        fixture.view.frame.size = CGSize(width: 780, height: 400)
        fixture.view.layoutIfNeeded()
        #expect(await fixture.wait { fixture.controller.size.columns > narrow.columns })
        #expect(stream.sizes.last == fixture.controller.size)

        let wide = fixture.controller.size
        fixture.controller.changeFontSize(by: 13)
        #expect(fixture.controller.preferences.fontSize == 26)
        #expect(fixture.controller.size.columns < wide.columns)
        #expect(stream.sizes.last == fixture.controller.size)
        #expect(fixture.controller.size.pixelWidth > 0)
    }

    /// A program that turned on SGR mouse reporting gets a tap as a click, press and release, at
    /// the cell tapped, counted from 1 (README section 5).
    @Test func tapIsSentAsAClickInMouseMode() async {
        let fixture = TerminalFixture()
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        // Without mouse reporting, a tap is the terminal's own.
        #expect(!fixture.view.forwardTap(at: fixture.point(column: 2, row: 1)))
        fixture.feed("\u{1B}[?1000h\u{1B}[?1006h")
        #expect(fixture.view.forwardTap(at: fixture.point(column: 2, row: 1)))
        #expect(await fixture.wait { stream.sentText == "\u{1B}[<0;3;2M\u{1B}[<0;3;2m" })
        // VoiceOver's double tap asks for the keyboard; it is not a click in the middle.
        _ = fixture.view.accessibilityActivate()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stream.sentText == "\u{1B}[<0;3;2M\u{1B}[<0;3;2m")
    }

    /// With bracketed paste on, a paste goes at once, marked as one.
    @Test func bracketedPasteSendsAtOnce() async {
        let fixture = TerminalFixture()
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        fixture.feed("\u{1B}[?2004h")
        fixture.controller.terminalView(fixture.view, wantsToPaste: "make\nmake install")
        #expect(fixture.controller.pendingPaste == nil)
        #expect(await fixture.wait { stream.sentText == "\u{1B}[200~make\nmake install\u{1B}[201~" })
    }

    /// Without bracketed paste, a paste of more lines waits for the user, who sees how many.
    @Test func pasteOfMoreLinesAsksFirst() async {
        let fixture = TerminalFixture()
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        fixture.controller.terminalView(fixture.view, wantsToPaste: "cd /srv\nrm -rf cache\nls")
        #expect(fixture.controller.pendingPaste?.lineCount == 3)
        #expect(stream.sent.isEmpty)

        fixture.controller.cancelPaste()
        #expect(fixture.controller.pendingPaste == nil)
        #expect(stream.sent.isEmpty)

        fixture.controller.terminalView(fixture.view, wantsToPaste: "cd /srv\nls")
        fixture.controller.confirmPaste()
        // Each line ends with a carriage return, as typed.
        #expect(await fixture.wait { stream.sentText == "cd /srv\rls" })

        fixture.controller.terminalView(fixture.view, wantsToPaste: "uptime")
        #expect(fixture.controller.pendingPaste == nil)
        #expect(await fixture.wait { stream.sentText == "cd /srv\rlsuptime" })
    }

    /// The bell taps and flashes, at most twice a second. A terminal that is not on screen only
    /// marks its tab, until the terminal is seen (README section 5).
    @Test func bellTapsFlashesAndMarksATerminalOffScreen() async {
        let fixture = TerminalFixture()
        fixture.controller.isVisible = false
        fixture.feed("\u{7}")
        #expect(await fixture.wait { fixture.controller.hasUnseenBell })
        #expect(fixture.recorded.taps == 0)
        #expect(!fixture.view.isFlashingForBell)
        fixture.controller.isVisible = true
        #expect(!fixture.controller.hasUnseenBell)

        // SwiftTerm lets one bell through every 100 ms.
        try? await Task.sleep(for: .milliseconds(150))
        fixture.feed("\u{7}")
        #expect(await fixture.wait { fixture.recorded.taps == 1 })
        #expect(fixture.view.isFlashingForBell)
        // A second bell right after the first is not felt again.
        try? await Task.sleep(for: .milliseconds(150))
        fixture.feed("\u{7}")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(fixture.recorded.taps == 1)
        #expect(!fixture.controller.hasUnseenBell)
    }

    @Test func bellGateAllowsTwoASecond() {
        var gate = BellGate()
        let start = ContinuousClock.now
        let first = gate.allows(at: start)
        let tooSoon = gate.allows(at: start.advanced(by: .milliseconds(499)))
        let halfASecondLater = gate.allows(at: start.advanced(by: .milliseconds(500)))
        #expect(first)
        #expect(!tooSoon)
        #expect(halfASecondLater)
    }

    /// Wide characters, combining marks, emoji and flags take the columns xterm and wcwidth()
    /// give them, so a program's cursor and the screen never drift (README section 5).
    @Test func unicodeTakesTheColumnsXtermGivesIt() throws {
        let fixture = TerminalFixture()
        fixture.feed("漢a🙂b🇨🇭ce\u{301}d")
        let snapshot = fixture.view.terminalStateSnapshot()
        let row = try #require(snapshot.visibleRows.first)
        #expect(row.cellWidths.prefix(11) == [2, 0, 1, 2, 0, 1, 2, 0, 1, 1, 1])
        #expect(snapshot.cursor.col == 11)
        #expect(row.text.hasPrefix("漢a🙂b🇨🇭ce\u{301}d"))
    }

    /// 10,000 lines of scrollback by default, and the length the user sets.
    @Test func keepsTheScrollbackItIsSet() async {
        let fixture = TerminalFixture()
        let rows = fixture.view.terminalDimensions.rows
        fixture.feed((1...12_000).map { "line \($0)\r\n" }.joined())
        let lines = { String(decoding: fixture.view.getBufferAsData(), as: UTF8.self).split(separator: "\n").count }
        #expect(lines() <= rows + 10_000)
        #expect(lines() > 10_000)
        fixture.controller.preferences.scrollbackLines = 1_000
        #expect(lines() <= rows + 1_000)
    }

    /// A match on the continuation of a wrapped line, such as a command after a prompt wider than
    /// the terminal, is found again when the search goes on up from it, round from the top.
    @Test func searchGoesRoundToAMatchOnAWrappedLine() async {
        let fixture = TerminalFixture()
        #expect(await fixture.settle())
        let prompt = String(repeating: "h", count: fixture.controller.size.columns + 10) + ":~ $ "
        fixture.feed("Last login: today\r\n" + prompt + "uname\r\nDarwin\r\n" + prompt)

        let match = TerminalController.SearchResult(index: 1, total: 1)
        #expect(fixture.controller.search(for: "uname") == match)
        #expect(fixture.controller.search(for: "uname") == match)
        #expect(fixture.view.getSelection() == "uname")
    }

    /// Search goes up from the bottom first, to the most recent match, and counts the matches.
    /// While the term is typed, the match stays as long as it still matches.
    @Test func searchFindsTheMostRecentMatchFirst() async {
        let fixture = TerminalFixture()
        fixture.feed((1...300).map { $0 % 100 == 0 ? "needle \($0)\r\n" : "hay \($0)\r\n" }.joined())
        let match = { (index: Int) in TerminalController.SearchResult(index: index, total: 3) }
        #expect(fixture.controller.search(for: "need") == match(3))
        #expect(fixture.controller.search(for: "NEEDLE") == match(3))
        #expect(fixture.view.getSelection() == "needle")
        #expect(fixture.controller.search(for: "NEEDLE") == match(2))
        #expect(fixture.controller.search(for: "NEEDLE", backwards: false) == match(3))
        // Down from the last match goes round to the first.
        #expect(fixture.controller.search(for: "NEEDLE", backwards: false) == match(1))
        #expect(fixture.controller.search(for: "missing") == .none)
        fixture.controller.endSearch()
        #expect(!fixture.view.hasActiveSelection)
    }

    /// SwiftTerm drops its selection when the grid changes, as it does when the keyboard comes or
    /// goes; the search selects its match again.
    @Test func keepsTheSearchMatchWhenTheGridChanges() async {
        let fixture = TerminalFixture()
        #expect(await fixture.settle())
        fixture.feed((1...300).map { $0 % 100 == 0 ? "needle \($0)\r\n" : "hay \($0)\r\n" }.joined())
        let match = { (index: Int) in TerminalController.SearchResult(index: index, total: 3) }
        fixture.controller.search(for: "needle")
        #expect(fixture.controller.search(for: "needle") == match(2))

        let rows = fixture.controller.size.rows
        fixture.view.frame.size.height -= 100
        fixture.view.layoutIfNeeded()
        #expect(await fixture.wait { fixture.controller.size.rows < rows })
        #expect(fixture.view.hasActiveSelection)
        #expect(fixture.controller.searchResult == match(2))
        // Up from it, as before.
        #expect(fixture.controller.search(for: "needle") == match(1))
    }

    /// Counting stops at a thousand matches: the most recent ones then have no index.
    @Test func countsAThousandMatchesAtMost() {
        let fixture = TerminalFixture()
        fixture.feed(String(repeating: "needle\r\n", count: 1_200))
        let result = fixture.controller.search(for: "needle")
        #expect(result == TerminalController.SearchResult(index: 0, total: 1_000))
        #expect(result.isCapped)
        #expect(result.spokenDescription == "\(1_000.formatted()) or more matches")
    }

    /// With VoiceOver, a search says which match it found and reads the line it is on.
    @Test func announcesTheSearchResultWithItsLine() {
        let fixture = TerminalFixture(voiceOver: true)
        fixture.feed("make\r\nerror: missing semicolon\r\nok\r\nerror: no such file\r\n")
        fixture.controller.search(for: "ERROR")
        fixture.controller.announceSearchResult()
        fixture.controller.search(for: "ERROR")
        fixture.controller.announceSearchResult()
        fixture.controller.search(for: "warning")
        fixture.controller.announceSearchResult()
        #expect(
            fixture.recorded.announcements == [
                "Match 2 of 2: error: no such file", "Match 1 of 2: error: missing semicolon", "No matches",
            ])
    }

    /// A match that runs over the end of a row, in a line too long for the screen, counts for the
    /// search, but not for the line VoiceOver reads: then only the count is read, rather than
    /// another match's line.
    @Test func readsOnlyTheCountWhenAMatchWrapsAcrossRows() {
        let fixture = TerminalFixture(voiceOver: true)
        let columns = fixture.view.terminalDimensions.cols
        fixture.feed("needle first\r\n" + String(repeating: "x", count: columns - 3) + "needle\r\n")
        fixture.controller.search(for: "needle")
        fixture.controller.announceSearchResult()
        #expect(fixture.recorded.announcements == ["Match 2 of 2"])
        #expect(TerminalController.line(ofMatch: 1, of: "needle", in: "a needle\nb", total: 1) == "a needle")
    }

    /// A long-press selects the word under it; Copy, which is SwiftTerm's, puts the selection on
    /// the pasteboard as plain text (TerminalTests in the UI tests).
    @Test func selectsTheWordUnderAPoint() async {
        let fixture = TerminalFixture()
        fixture.feed("ssh deploy@prod-api-01")
        #expect(fixture.view.selectWord(at: fixture.point(column: 12, row: 0)))
        #expect(fixture.view.getSelection() == "prod-api-01")
        #expect(!fixture.view.selectWord(at: fixture.point(column: 3, row: 0)))
    }

    /// The edit menu offers the system's actions, without SwiftTerm's Select, and Paste only with
    /// text to paste.
    @Test func editMenuLeavesOutSelect() {
        let actions: [UIMenuElement] = [
            UIMenu(
                options: .displayInline,
                children: [
                    UICommand(title: "Copy", action: #selector(UIResponderStandardEditActions.copy(_:))),
                    UICommand(title: "Select", action: #selector(UIResponderStandardEditActions.select(_:))),
                    UICommand(title: "Paste", action: #selector(UIResponderStandardEditActions.paste(_:))),
                ])
        ]
        let titles = { (elements: [UIMenuElement]) in
            (elements.first as? UIMenu)?.children.map(\.title) ?? []
        }
        #expect(titles(TerminalHostView.editActions(actions, canPaste: true)) == ["Copy", "Paste"])
        #expect(titles(TerminalHostView.editActions(actions, canPaste: false)) == ["Copy"])
    }

    @Test func readsTheCurrentLine() async {
        let fixture = TerminalFixture()
        fixture.feed("first\r\n  second line")
        fixture.controller.readCurrentLine()
        #expect(fixture.recorded.announcements == ["second line"])
    }

    /// With VoiceOver, new output is read out; without it, nothing is.
    @Test func announcesNewOutputOnlyWithVoiceOver() async {
        let silent = TerminalFixture()
        let quiet = RecordingStream()
        silent.controller.isVisible = true
        silent.controller.attach(quiet)
        quiet.write("build finished\r\n")
        #expect(await silent.wait { silent.screen.first == "build finished" })
        silent.controller.announceNewOutput()
        #expect(silent.recorded.announcements.isEmpty)

        let fixture = TerminalFixture(voiceOver: true)
        let stream = RecordingStream()
        fixture.controller.isVisible = true
        fixture.controller.attach(stream)
        stream.write("build finished\r\n")
        #expect(await fixture.wait { fixture.screen.first == "build finished" })
        fixture.controller.announceNewOutput()
        #expect(fixture.recorded.announcements == ["build finished"])
        // It does not cut off what VoiceOver is saying.
        #expect(fixture.recorded.priorities == [.low])
    }

    /// Output is read only while the terminal is on screen, and only once VoiceOver has finished
    /// reading the output before.
    @Test func readsOutputOnScreenAfterTheOutputBefore() async {
        let fixture = TerminalFixture(voiceOver: true)
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        stream.write("first\r\n")
        #expect(await fixture.wait { fixture.screen.first == "first" })
        fixture.controller.announceNewOutput()
        #expect(fixture.recorded.announcements.isEmpty)

        fixture.controller.isVisible = true
        fixture.controller.announceNewOutput()
        stream.write("second\r\n")
        #expect(await fixture.wait { fixture.screen.prefix(2) == ["first", "second"] })
        fixture.controller.announceNewOutput()
        #expect(fixture.recorded.announcements == ["first"])

        NotificationCenter.default.post(
            name: UIAccessibility.announcementDidFinishNotification, object: nil,
            userInfo: [
                UIAccessibility.announcementStringValueUserInfoKey: "first",
                UIAccessibility.announcementWasSuccessfulUserInfoKey: true,
            ])
        #expect(
            await fixture.wait {
                fixture.controller.announceNewOutput()
                return fixture.recorded.announcements == ["first", "second"]
            })
    }

    /// The actions for assistive technologies copy the current line and the screen, and change
    /// the text size without a pinch.
    @Test func accessibilityActionsCopyAndChangeTheTextSize() {
        let fixture = TerminalFixture(voiceOver: true)
        let controller = fixture.controller
        #expect(
            fixture.view.accessibilityCustomActions?.map(\.name) == [
                "Read Current Line", "Copy Current Line", "Copy Screen", "Bigger Text", "Smaller Text",
            ])
        fixture.feed("total 0\r\n$ ls")
        controller.terminalView(fixture.view, performs: .copyCurrentLine)
        controller.terminalView(fixture.view, performs: .copyScreen)
        #expect(fixture.recorded.copied == ["$ ls", "total 0\n$ ls"])
        #expect(fixture.recorded.announcements == ["Copied", "Copied"])

        controller.terminalView(fixture.view, performs: .biggerText)
        #expect(controller.preferences.fontSize == 14)
        controller.terminalView(fixture.view, performs: .smallerText)
        controller.terminalView(fixture.view, performs: .smallerText)
        #expect(controller.preferences.fontSize == 12)
        // At either end, VoiceOver hears why nothing changed.
        controller.preferences.fontSize = TerminalPreferences.fontSizes.upperBound
        controller.terminalView(fixture.view, performs: .biggerText)
        #expect(fixture.recorded.announcements.last == "Largest text size")
    }

    /// A connection that dropped while vim was up leaves the alternate screen and mouse reporting on:
    /// readied for the next connection, the terminal is back on the scrollback, with the cursor
    /// where it was before vim, and a tap is a tap again, not a click sent to a program that is gone.
    @Test func readiesForTheNextConnectionAfterAFullScreenProgram() async {
        let fixture = TerminalFixture()
        let first = RecordingStream()
        fixture.controller.attach(first)
        first.write("shell before vim\r\n$ vim\u{1B}[?1049h\u{1B}[2J\u{1B}[Hvim's screen\u{1B}[?1000h\u{1B}[?1006h")
        #expect(await fixture.wait { fixture.screen.first == "vim's screen" })
        #expect(fixture.view.forwardTap(at: fixture.point(column: 2, row: 0)))
        first.finish(throwing: Dropped())
        #expect(await fixture.wait { fixture.controller.streamState != .attached })

        fixture.controller.prepareForNextConnection()
        let second = RecordingStream()
        fixture.controller.attach(second)
        second.write("after")

        #expect(await fixture.wait { fixture.screen.prefix(3) == ["shell before vim", "$ vim", "after"] })
        #expect(!fixture.view.forwardTap(at: fixture.point(column: 2, row: 0)))
    }

    /// Without a full-screen program, the reset leaves the cursor where it is: the next connection's
    /// output starts on the next line.
    @Test func readiesForTheNextConnectionOnTheNextLine() async {
        let fixture = TerminalFixture()
        let first = RecordingStream()
        fixture.controller.attach(first)
        first.write("one\r\ntwo\r\n$ ")
        #expect(await fixture.wait { fixture.screen.prefix(3) == ["one", "two", "$"] })
        first.finish(throwing: Dropped())
        #expect(await fixture.wait { fixture.controller.streamState != .attached })

        fixture.controller.prepareForNextConnection()
        let second = RecordingStream()
        fixture.controller.attach(second)
        second.write("after")

        #expect(await fixture.wait { fixture.screen.prefix(4) == ["one", "two", "$", "after"] })
    }

    /// A program's window title names the tab, cleaned of what could make it read as something else.
    @Test(arguments: [
        ("vim compose.yml", "vim compose.yml"),
        ("deploy@prod-api-01: ~", "deploy@prod-api-01: ~"),
        ("two\nlines\t and\u{1B} controls", "two lines and controls"),
        ("\u{202E}lmth.exe", "lmth.exe"),
        (String(repeating: "x", count: 200), String(repeating: "x", count: 64)),
    ])
    func windowTitleNamesTheTab(_ title: String, shown: String) async {
        let fixture = TerminalFixture()
        let stream = RecordingStream()
        fixture.controller.attach(stream)

        fixture.controller.setTerminalTitle(source: fixture.view, title: title)

        #expect(fixture.controller.title == shown)
        fixture.controller.prepareForNextConnection()
        #expect(fixture.controller.title.isEmpty)
    }

    /// When a stream ends, the terminal keeps its screen, and attaches to the next stream with its
    /// size: the way a tab reconnects.
    @Test func outlivesItsStreams() async {
        let fixture = TerminalFixture()
        let first = RecordingStream()
        fixture.controller.attach(first)
        first.write("before the drop\r\n")
        first.finish()
        #expect(await fixture.wait { fixture.controller.streamState == .ended })

        let second = RecordingStream()
        fixture.controller.attach(second)
        #expect(second.sizes == [fixture.controller.size])
        second.write("after")
        #expect(await fixture.wait { fixture.screen.prefix(2) == ["before the drop", "after"] })

        struct Dropped: Error {}
        second.finish(throwing: Dropped())
        #expect(await fixture.wait { if case .failed = fixture.controller.streamState { true } else { false } })
        fixture.controller.detach()
        #expect(fixture.controller.streamState == .detached)
    }

    /// Output is parsed off the main actor in slices, so a large chunk never holds the terminal
    /// for long.
    @Test func feedsLargeChunksInSlices() async {
        let fixture = TerminalFixture()
        let stream = RecordingStream()
        fixture.controller.attach(stream)
        let line = String(repeating: "x", count: 99) + "\n"
        stream.write(String(repeating: line, count: 1000) + "\r\nend")
        #expect(await fixture.wait { fixture.screen.contains("end") })
        #expect(fixture.view.diagnostics.batches >= 100_000 / TerminalController.maximumFeedBytes)
    }
}

/// A connection that dropped under the terminal's stream.
private struct Dropped: Error {}
