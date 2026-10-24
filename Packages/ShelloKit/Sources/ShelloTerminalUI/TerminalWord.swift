/// The word under a long-press, in one row of a terminal (README section 5).
///
/// A word is a run of letters, digits and the characters iTerm2 counts as part of a word by
/// default, `/ - + \ ~ _ .`, so that a long-press on a path or a host name selects all of it.
nonisolated enum TerminalWord {
    /// The columns of the word that covers `column`, its end exclusive, or nil when that cell is
    /// blank or punctuation. `cells` holds a row's characters, one per column, with nil for the
    /// second column of a wide character.
    static func columns(at column: Int, in cells: [Character?]) -> Range<Int>? {
        guard cells.indices.contains(column) else { return nil }
        // The second column of a wide character belongs to the character before it.
        var anchor = column
        while anchor > 0, cells[anchor] == nil {
            anchor -= 1
        }
        guard let character = cells[anchor], isWordCharacter(character) else { return nil }
        var start = anchor
        while start > 0, belongsToWord(cells[start - 1]) {
            start -= 1
        }
        // A word never starts on the second column of a wide character.
        while start < anchor, cells[start] == nil {
            start += 1
        }
        var end = anchor + 1
        while end < cells.count, belongsToWord(cells[end]) {
            end += 1
        }
        return start..<end
    }

    /// The row's characters, one per column: `text` holds the characters of the columns whose
    /// width is not zero, and `widths` the width of every column, with 0 for the second column of
    /// a wide character. This is how SwiftTerm copies a row (`TerminalVisibleRowSnapshot`).
    static func cells(text: String, widths: [Int]) -> [Character?] {
        var characters = text.makeIterator()
        return widths.map { width in
            width == 0 ? nil : (characters.next() ?? " ")
        }
    }

    /// Whether a cell continues a word. The second column of a wide character goes with the first,
    /// which is checked on its own.
    private static func belongsToWord(_ cell: Character?) -> Bool {
        cell.map(isWordCharacter) ?? true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "/-+\\~_.".contains(character)
    }
}
