import Testing

@testable import ShelloTerminalUI

/// Paste asks first when more than one line would run as commands (README section 5).
@Suite struct PastePolicyTests {
    @Test(arguments: [
        ("", 0), ("ls", 1), ("ls\n", 1), ("ls\r\n", 1), ("ls\r", 1), ("one\ntwo", 2), ("one\r\ntwo\r\n", 2),
        ("one\n\nthree", 3), ("\n", 1), ("a\rb\rc", 3),
    ])
    func countsLines(text: String, lines: Int) {
        #expect(PastePolicy.lineCount(of: text) == lines)
    }

    @Test func oneLinePastesAtOnce() {
        #expect(PastePolicy.decision(for: "uptime", bracketedPasteMode: false) == .paste)
        // A line with its line break runs, as typing it and Return would.
        #expect(PastePolicy.decision(for: "uptime\n", bracketedPasteMode: false) == .paste)
    }

    @Test func moreLinesAskFirstWithTheirCount() {
        let text = "cd /srv\nrm -rf cache\nls\n"
        #expect(PastePolicy.decision(for: text, bracketedPasteMode: false) == .confirm(lineCount: 3))
    }

    /// With bracketed paste on, the program receives the text marked as a paste and runs nothing.
    @Test func bracketedPastePastesAtOnce() {
        #expect(PastePolicy.decision(for: "one\ntwo\nthree", bracketedPasteMode: true) == .paste)
    }
}
