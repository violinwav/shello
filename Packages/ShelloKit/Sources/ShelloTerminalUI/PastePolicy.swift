/// Whether a paste goes to the terminal at once or asks first (README section 5).
///
/// With bracketed paste on, which the program on the server turns on with `CSI ? 2004 h`, the
/// text arrives marked as a paste and the program decides what to do with it. Without it, every
/// line ends in a carriage return as it arrives, which runs it as a command, so text of more than
/// one line asks first and says how many lines it has.
nonisolated enum PastePolicy {
    enum Decision: Equatable {
        case paste
        case confirm(lineCount: Int)
    }

    static func decision(for text: String, bracketedPasteMode: Bool) -> Decision {
        guard !bracketedPasteMode else { return .paste }
        let lines = lineCount(of: text)
        return lines > 1 ? .confirm(lineCount: lines) : .paste
    }

    /// The number of lines in `text`. A line break at the very end ends the last line rather than
    /// starting another; CR LF counts as one break, and so does a lone CR, which the terminal sends
    /// as Return too.
    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // Swift treats "\r\n" as a single Character, so each break counts once.
        let breaks = text.filter { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }.count
        let endsWithBreak = text.last.map { $0 == "\n" || $0 == "\r" || $0 == "\r\n" } ?? false
        return endsWithBreak ? breaks : breaks + 1
    }
}
