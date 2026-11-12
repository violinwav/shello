import Testing

@testable import ShelloTerminalUI

/// A long-press selects the word under it (README section 5).
@Suite struct TerminalWordTests {
    private func cells(_ text: String) -> [Character?] {
        text.map { $0 }
    }

    @Test func selectsTheWordUnderTheColumn() {
        let row = cells("deploy@prod-api-01:~$ ls")
        #expect(TerminalWord.columns(at: 2, in: row) == 0..<6)
        // A host name with dashes and digits is one word; the @ and : around it are not.
        #expect(TerminalWord.columns(at: 9, in: row) == 7..<18)
        #expect(TerminalWord.columns(at: 6, in: row) == nil)
        #expect(TerminalWord.columns(at: 23, in: row) == 22..<24)
    }

    @Test func pathsAreOneWord() {
        let row = cells("cat /var/log/nginx/access.log")
        #expect(TerminalWord.columns(at: 10, in: row) == 4..<29)
    }

    @Test func blanksAndPunctuationSelectNothing() {
        let row = cells("a  (b)")
        #expect(TerminalWord.columns(at: 1, in: row) == nil)
        #expect(TerminalWord.columns(at: 3, in: row) == nil)
        #expect(TerminalWord.columns(at: 40, in: row) == nil)
    }

    /// A wide character takes two columns: its second column has no character of its own and
    /// selects the same word as the first.
    @Test func wideCharactersSelectWhole() {
        let row = TerminalWord.cells(text: "ab 漢字 c", widths: [1, 1, 1, 2, 0, 2, 0, 1, 1])
        #expect(row == ["a", "b", " ", "漢", nil, "字", nil, " ", "c"])
        #expect(TerminalWord.columns(at: 4, in: row) == 3..<7)
        #expect(TerminalWord.columns(at: 6, in: row) == 3..<7)
    }

    /// An emoji is not a letter, so a word stops at it, and its second column selects nothing.
    @Test func wordsStopAtEmoji() {
        let row = TerminalWord.cells(text: "ok🙂go", widths: [1, 1, 2, 0, 1, 1])
        #expect(TerminalWord.columns(at: 1, in: row) == 0..<2)
        #expect(TerminalWord.columns(at: 3, in: row) == nil)
        #expect(TerminalWord.columns(at: 4, in: row) == 4..<6)
    }

    /// SwiftTerm leaves out the unwritten cells at the end of a row.
    @Test func unwrittenCellsAreBlank() {
        let row = TerminalWord.cells(text: "ls", widths: [1, 1, 1, 1])
        #expect(row == ["l", "s", " ", " "])
    }
}
