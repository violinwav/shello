import Testing

@testable import ShelloTerminalUI

/// VoiceOver hears new output, throttled (README section 16, STACK section 7.14).
@Suite struct OutputAnnouncerTests {
    private let start = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(Int(seconds * 1000)))
    }

    @Test func readsNewLinesWithoutEscapeSequences() {
        var announcer = OutputAnnouncer()
        announcer.output(Array("\u{1B}[1;32mBuild\u{1B}[0m succeeded\r\n12 tests passed\r\n".utf8), at: at(0))
        #expect(announcer.announcement(at: at(0.1)) == "Build succeeded\n12 tests passed")
        // Nothing new: nothing to say.
        #expect(announcer.announcement(at: at(1.1)) == nil)
    }

    /// A long line is cut short: VoiceOver reads its first 200 characters.
    @Test func readsTheStartOfALongLine() {
        var announcer = OutputAnnouncer()
        let line = String(repeating: "x", count: 300)
        announcer.output(Array("  \(line)\r\n".utf8), at: at(0))
        #expect(announcer.announcement(at: at(0.1)) == String(repeating: "x", count: 200) + "…")
    }

    /// A prompt has no line end. It is read once the output pauses, and only once.
    @Test func readsAPromptOnceTheOutputPauses() {
        var announcer = OutputAnnouncer()
        announcer.output(Array("total 0\r\n$ ".utf8), at: at(0))
        #expect(announcer.announcement(at: at(0.5)) == "total 0")
        #expect(announcer.announcement(at: at(1.5)) == "$")
        #expect(announcer.announcement(at: at(2.5)) == nil)
    }

    /// The echo of what the user types is not read again: VoiceOver spoke the keys.
    @Test func leavesOutTheEchoOfTyping() {
        var announcer = OutputAnnouncer()
        announcer.output(Array("$ ".utf8), at: at(0))
        #expect(announcer.announcement(at: at(1)) == "$")
        announcer.input(Array("ls\r".utf8), at: at(2))
        announcer.output(Array("ls\r\nnotes.txt\r\n$ ".utf8), at: at(2.1))
        // The command's line is left out; its output and the new prompt are read.
        #expect(announcer.announcement(at: at(3.2)) == "notes.txt\n$")
    }

    /// Typing that never comes back, such as a password, does not hide later output.
    @Test func typingWithoutEchoExpiresAfterAnInterval() {
        var announcer = OutputAnnouncer()
        announcer.input(Array("secret\r".utf8), at: at(0))
        #expect(announcer.announcement(at: at(1.5)) == nil)
        announcer.output(Array("\r\nWelcome\r\n".utf8), at: at(2))
        #expect(announcer.announcement(at: at(2.5)) == "Welcome")
    }

    /// A flood is summed up once it pauses, rather than read line by line.
    @Test func sumsUpAFloodOnceItPauses() {
        var announcer = OutputAnnouncer()
        for second in 0..<3 {
            for line in 0..<1000 {
                announcer.output(Array("line \(second * 1000 + line)\r\n".utf8), at: at(Double(second)))
            }
            // Still flowing: nothing yet.
            #expect(announcer.announcement(at: at(Double(second) + 0.5)) == nil)
        }
        #expect(announcer.announcement(at: at(3.5)) == "3000 new lines, the last: line 2999")
    }

    /// Full-screen programs draw on the alternate screen; they are explored by touch, not read.
    @Test func staysQuietOnTheAlternateScreen() {
        var announcer = OutputAnnouncer()
        announcer.output(Array("\u{1B}[?1049h\u{1B}[H\u{1B}[2Jtop - 10:00 up 3 days\r\n".utf8), at: at(0))
        #expect(announcer.announcement(at: at(1.5)) == nil)
        announcer.output(Array("\u{1B}[?1049l$ ".utf8), at: at(2))
        #expect(announcer.announcement(at: at(3)) == "$")
    }

    /// Carriage returns redraw a line, as progress bars do; backspaces delete.
    @Test func followsCarriageReturnsAndBackspaces() {
        var extractor = PlainTextExtractor()
        var lines = CollectedLines()
        extractor.consume(Array("10%\r50%\r100% done\r\nab\u{8}c\r\n".utf8), into: &lines)
        #expect(lines.lines == ["100% done", "ac"])
    }

    /// A chunk can end anywhere, inside an escape sequence or a UTF-8 character.
    @Test func handlesChunksSplitAnywhere() {
        let text = Array("\u{1B}]0;title\u{7}Grüße \u{1B}[38;2;1;2;3m→\u{1B}[0m\r\n".utf8)
        for split in 1..<text.count {
            var extractor = PlainTextExtractor()
            var lines = CollectedLines()
            extractor.consume(text[..<split], into: &lines)
            extractor.consume(text[split...], into: &lines)
            #expect(lines.lines == ["Grüße →"], "split at \(split)")
        }
    }

    @Test func countsTypedCharactersNotKeys() {
        #expect(PlainTextExtractor.characterCount(ofTypedInput: Array("ls -la".utf8)) == 6)
        // Return, an arrow key's escape sequence, and Delete.
        #expect(PlainTextExtractor.characterCount(ofTypedInput: [0x0D, 0x1B, 0x5B, 0x41, 0x7F]) == 0)
        #expect(PlainTextExtractor.characterCount(ofTypedInput: Array("ü".utf8)) == 1)
    }
}

/// The lines a `PlainTextExtractor` ends.
private struct CollectedLines: PlainTextSink {
    var lines: [String] = []

    mutating func character() {}

    mutating func lineEnded(_ line: String) {
        lines.append(line)
    }
}
