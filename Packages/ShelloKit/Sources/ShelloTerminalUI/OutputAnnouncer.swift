import Foundation

/// What VoiceOver says about a terminal's new output, at most once per `interval` (README section
/// 16, STACK section 7.14).
///
/// It reads the output as plain text: escape sequences are dropped, and a line counts once it ends.
/// A few new lines are read out whole. A flood of them is summed up once the output pauses, so that
/// VoiceOver never falls behind. A line without an end, such as a prompt, is read once the output
/// pauses. What the user typed comes back from the server as echo; the line it is on is not read,
/// since VoiceOver has already spoken the keys. Full-screen programs, on the alternate screen, are
/// not read at all: they redraw the screen rather than add lines to it, and the user explores them
/// by touch.
nonisolated struct OutputAnnouncer {
    /// The shortest time between two announcements, and how long the output must pause before a
    /// flood or a prompt is announced.
    var interval: Duration = .seconds(1)

    private var text = PlainTextExtractor()
    private var lines = NewLines()
    private var lastOutput: ContinuousClock.Instant?
    private var lastInput: ContinuousClock.Instant?
    /// The unfinished line last read out, so that a prompt is read once.
    private var announcedPartialLine: String?

    /// Takes output as the terminal receives it.
    mutating func output(_ bytes: some Sequence<UInt8>, at now: ContinuousClock.Instant) {
        lastOutput = now
        text.consume(bytes, into: &lines)
    }

    /// Takes the user's input as the terminal sends it: what the server is expected to echo.
    mutating func input(_ bytes: some Sequence<UInt8>, at now: ContinuousClock.Instant) {
        lastInput = now
        lines.expectedEcho += PlainTextExtractor.characterCount(ofTypedInput: bytes)
    }

    /// The most characters of a line VoiceOver reads.
    static let maximumSpokenLength = 200

    /// `line` as VoiceOver reads it: without the blanks around it, and cut short after
    /// `maximumSpokenLength` characters.
    static func spoken(_ line: some StringProtocol) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maximumSpokenLength else { return trimmed }
        return String(trimmed.prefix(maximumSpokenLength)) + "…"
    }

    /// What to say now, if anything. Call it every `interval`.
    mutating func announcement(at now: ContinuousClock.Instant) -> String? {
        if text.isAlternateScreen {
            lines.removeAll()
            return nil
        }
        let isQuiet = lastOutput.map { now - $0 >= interval } ?? true
        // Typing that never came back, such as a password, is not echo.
        if let lastInput, now - lastInput >= interval {
            lines.expectedEcho = 0
        }
        // After a line ends, the same prompt is news again: the command before it has finished.
        if lines.anyLineEnded {
            announcedPartialLine = nil
        }
        var parts: [String] = []
        if lines.count > NewLines.maximumKept {
            // A flood: wait for it to pause, then sum it up.
            guard isQuiet else { return nil }
            parts.append("\(lines.count) new lines, the last: \(lines.kept.last ?? "")")
        } else if lines.count > 0 {
            parts.append(lines.kept.joined(separator: "\n"))
        }
        lines.removeAll()
        let partialLine = Self.spoken(text.currentLine)
        if isQuiet, !lines.lineHasEcho, !partialLine.isEmpty, partialLine != announcedPartialLine {
            parts.append(partialLine)
            announcedPartialLine = partialLine
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

/// The lines that ended since the last announcement.
nonisolated private struct NewLines: PlainTextSink {
    /// The most lines read out whole; more are summed up.
    static let maximumKept = 4

    /// The last lines, up to `maximumKept`.
    private(set) var kept: [String] = []
    /// How many lines ended.
    private(set) var count = 0
    /// Characters the user typed that have not come back as echo yet.
    var expectedEcho = 0
    /// Whether the current line holds echo of the user's typing.
    private(set) var lineHasEcho = false
    /// Whether any line ended, read out or not.
    private(set) var anyLineEnded = false

    mutating func character() {
        if expectedEcho > 0 {
            expectedEcho -= 1
            lineHasEcho = true
        }
    }

    mutating func lineEnded(_ line: String) {
        if !lineHasEcho, !line.allSatisfy(\.isWhitespace) {
            count += 1
            kept.append(OutputAnnouncer.spoken(line))
            if kept.count > Self.maximumKept {
                kept.removeFirst()
            }
        }
        lineHasEcho = false
        expectedEcho = 0
        anyLineEnded = true
    }

    mutating func removeAll() {
        kept.removeAll()
        count = 0
        anyLineEnded = false
    }
}

/// Receives terminal output as plain text.
nonisolated protocol PlainTextSink {
    /// A printable character was added to the current line.
    mutating func character()
    /// A line ended, with its text.
    mutating func lineEnded(_ line: String)
}

/// Terminal output as plain text, for VoiceOver: printable characters and line ends, without
/// escape sequences or control characters. It notes whether the alternate screen is on.
nonisolated struct PlainTextExtractor {
    /// The text of the line not ended yet, after carriage returns and backspaces.
    var currentLine: String { String(decoding: line, as: UTF8.self) }
    /// Whether the program switched to the alternate screen, as full-screen programs do.
    private(set) var isAlternateScreen = false

    private enum State {
        case text
        case escape
        /// An escape sequence with intermediate bytes, such as a character set designation.
        case escapeIntermediate
        /// A control sequence: parameters and intermediates, then a final byte.
        case controlSequence
        /// An operating system command, until BEL or ST.
        case operatingSystemCommand
        /// A device control string, or another string sequence, until ST.
        case string
        /// Escape inside an operating system command or a string: a backslash ends it.
        case stringEscape(inCommand: Bool)
    }

    private var state = State.text
    private var line: [UInt8] = []
    /// After a carriage return, the next printable character starts the line again.
    private var overwritesLine = false
    private var parameters: [UInt8] = []

    /// The longest line kept: output without line ends must not grow it without bound.
    private static let maximumLineBytes = 4096

    mutating func consume(_ bytes: some Sequence<UInt8>, into sink: inout some PlainTextSink) {
        for byte in bytes {
            switch state {
            case .text: text(byte, into: &sink)
            case .escape: escape(byte)
            case .escapeIntermediate:
                if byte >= 0x30 { state = .text }
            case .controlSequence:
                if (0x40...0x7E).contains(byte) {
                    finishControlSequence(final: byte)
                } else {
                    parameters.append(byte)
                }
            case .operatingSystemCommand:
                if byte == 0x07 {
                    state = .text
                } else if byte == 0x1B {
                    state = .stringEscape(inCommand: true)
                }
            case .string:
                if byte == 0x1B { state = .stringEscape(inCommand: false) }
            case .stringEscape(let inCommand):
                if byte == UInt8(ascii: "\\") {
                    state = .text
                } else {
                    state = inCommand ? .operatingSystemCommand : .string
                }
            }
        }
    }

    private mutating func text(_ byte: UInt8, into sink: inout some PlainTextSink) {
        // A full-screen program's text is not read as lines: only its way back counts.
        if isAlternateScreen, byte != 0x1B {
            return
        }
        switch byte {
        case 0x1B:
            state = .escape
        case 0x0A, 0x0B, 0x0C:
            sink.lineEnded(currentLine)
            line.removeAll(keepingCapacity: true)
            overwritesLine = false
        case 0x0D:
            overwritesLine = true
        case 0x08:
            // Backspace removes the last character, with its UTF-8 continuation bytes.
            while let last = line.popLast(), last & 0xC0 == 0x80 {}
        case 0x09:
            append(UInt8(ascii: " "), into: &sink)
        case 0x00..<0x20, 0x7F:
            break
        default:
            append(byte, into: &sink)
        }
    }

    private mutating func append(_ byte: UInt8, into sink: inout some PlainTextSink) {
        if overwritesLine {
            line.removeAll(keepingCapacity: true)
            overwritesLine = false
        }
        if line.count >= Self.maximumLineBytes {
            line.removeFirst(line.count / 2)
        }
        line.append(byte)
        // One call per character: continuation bytes belong to the character before them.
        if byte & 0xC0 != 0x80 {
            sink.character()
        }
    }

    private mutating func escape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "["):
            parameters.removeAll(keepingCapacity: true)
            state = .controlSequence
        case UInt8(ascii: "]"):
            state = .operatingSystemCommand
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            state = .string
        case 0x20...0x2F:
            state = .escapeIntermediate
        default:
            state = .text
        }
    }

    /// Notes the modes that switch the alternate screen on and off (DECSET 47, 1047 and 1049).
    private mutating func finishControlSequence(final: UInt8) {
        state = .text
        guard final == UInt8(ascii: "h") || final == UInt8(ascii: "l"),
            parameters.first == UInt8(ascii: "?")
        else { return }
        let modes = String(decoding: parameters.dropFirst(), as: UTF8.self).split(separator: ";")
        if modes.contains(where: { $0 == "47" || $0 == "1047" || $0 == "1049" }) {
            isAlternateScreen = final == UInt8(ascii: "h")
            // The normal screen's line goes on where it was left.
            overwritesLine = false
        }
    }

    /// The characters in typed input that a server echoes: printable characters, not escape
    /// sequences such as arrow keys, nor control characters such as Return.
    static func characterCount(ofTypedInput bytes: some Sequence<UInt8>) -> Int {
        var count = 0
        var inEscape = false
        for byte in bytes {
            if inEscape {
                // A key's escape sequence ends with a letter or a tilde.
                if (0x40...0x7E).contains(byte), byte != UInt8(ascii: "["), byte != UInt8(ascii: "O") {
                    inEscape = false
                }
            } else if byte == 0x1B {
                inEscape = true
            } else if byte >= 0x20, byte != 0x7F, byte & 0xC0 != 0x80 {
                count += 1
            }
        }
        return count
    }
}
