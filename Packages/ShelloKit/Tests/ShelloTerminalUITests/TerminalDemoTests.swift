import ShelloModel
import Testing

@testable import ShelloTerminalUI

/// The terminal demo: a stand-in for a shell that echoes, runs its commands, and prints 10 MB on
/// demand without running ahead of the terminal.
@Suite struct TerminalDemoTests {
    /// Everything the shell has to say now, as text.
    private func output(of shell: inout DemoShell) -> String {
        String(decoding: shell.takeOutput() ?? [], as: UTF8.self)
    }

    @Test func greetsWithThePrompt() {
        var shell = DemoShell()
        let welcome = output(of: &shell)
        #expect(welcome.contains("Shello terminal demo"))
        #expect(welcome.hasSuffix(DemoScreens.prompt))
        #expect(shell.takeOutput() == nil)
    }

    @Test func echoesTypingAndDeletes() {
        var shell = DemoShell()
        _ = output(of: &shell)
        shell.handle(.input(Array("lz".utf8)))
        #expect(output(of: &shell) == "lz")
        shell.handle(.input([0x7F]))
        #expect(output(of: &shell) == "\u{8} \u{8}")
        shell.handle(.input(Array("s\r".utf8)))
        #expect(output(of: &shell) == "s\r\n" + DemoScreens.commandNotFound("ls") + DemoScreens.prompt)
    }

    @Test func runsCommandsTypedAtThePrompt() {
        var shell = DemoShell()
        _ = output(of: &shell)
        shell.handle(.input(Array("unicode\r".utf8)))
        let text = output(of: &shell)
        #expect(text.hasPrefix("unicode\r\n"))
        #expect(text.contains("漢字かなカナ"))
        #expect(text.hasSuffix(DemoScreens.prompt))
    }

    /// The Demo menu runs a command as if it was typed, leaving a screen that is still up.
    @Test func menuCommandsLeaveTheAlternateScreenFirst() {
        var shell = DemoShell()
        _ = output(of: &shell)
        shell.handle(.command(.alternate))
        #expect(output(of: &shell).contains("\u{1B}[?1049h"))
        // Keys other than q do nothing on the alternate screen.
        shell.handle(.input(Array("x".utf8)))
        #expect(shell.takeOutput() == nil)
        shell.handle(.command(.size))
        let text = output(of: &shell)
        #expect(text.hasPrefix(DemoScreens.leaveAlternateScreen + DemoScreens.prompt + "size\r\n"))
        #expect(text.contains("80 columns, 24 rows"))
    }

    @Test func knowsTheSizeTheTerminalReports() {
        var shell = DemoShell()
        _ = output(of: &shell)
        shell.handle(.resize(TerminalSize(columns: 48, rows: 30)))
        shell.handle(.command(.size))
        #expect(output(of: &shell).contains("48 columns, 30 rows"))
    }

    /// In mouse mode, an SGR mouse report of a left click is printed with its cell; releases,
    /// wheel and motion reports are not.
    @Test func printsMouseClicks() {
        var shell = DemoShell()
        _ = output(of: &shell)
        shell.handle(.command(.mouse))
        #expect(output(of: &shell).contains(DemoScreens.mouseOn))
        shell.handle(.input(Array("\u{1B}[<0;12;5M\u{1B}[<0;12;5m\u{1B}[<64;3;3M".utf8)))
        #expect(output(of: &shell) == DemoScreens.click(column: 12, row: 5))
        shell.handle(.input(Array("q".utf8)))
        #expect(output(of: &shell) == DemoScreens.mouseOff + DemoScreens.prompt)
    }

    /// A key's escape sequence can arrive split across two sends.
    @Test func joinsInputSplitAcrossSends() {
        var shell = DemoShell()
        _ = output(of: &shell)
        shell.handle(.command(.mouse))
        _ = output(of: &shell)
        shell.handle(.input(Array("\u{1B}[<0;7".utf8)))
        #expect(shell.takeOutput() == nil)
        shell.handle(.input(Array(";9M".utf8)))
        #expect(output(of: &shell) == DemoScreens.click(column: 7, row: 9))
    }

    /// Text pasted with bracketed paste keeps its line breaks until Return runs every line.
    @Test func bracketedPasteRunsOnReturn() {
        var shell = DemoShell()
        _ = output(of: &shell)
        shell.handle(.command(.paste))
        #expect(output(of: &shell).contains(DemoScreens.bracketedPasteOn))
        shell.handle(.input(Array("\u{1B}[200~size\rclear\u{1B}[201~".utf8)))
        #expect(output(of: &shell) == "size\r\nclear")
        shell.handle(.input([0x0D]))
        let text = output(of: &shell)
        #expect(text.contains("80 columns, 24 rows"))
        #expect(text.contains("\u{1B}[2J"))
    }

    /// The output test prints 10 MB of whole lines in chunks, then a summary and the prompt.
    /// Typing during it is echoed before the next chunk, which starts a line of its own.
    @Test func floodPrintsTenMegabytesAndEchoesTypingAtOnce() {
        var shell = DemoShell()
        _ = output(of: &shell)
        shell.handle(.input(Array("flood\r".utf8)))
        #expect(output(of: &shell) == "flood\r\n")
        var bytes = 0
        var chunks = 0
        while let chunk = shell.nextFloodChunk() {
            if chunks == 10 {
                shell.handle(.input(Array("x".utf8)))
                #expect(shell.takeOutput() == Array("x".utf8))
            }
            let isSummary = String(decoding: chunk, as: UTF8.self).contains("Printed 10.0 MB")
            if isSummary {
                #expect(String(decoding: chunk, as: UTF8.self).hasSuffix(DemoScreens.prompt + "x"))
                break
            }
            #expect(chunk.count <= DemoShell.floodChunkBytes)
            #expect(chunk.suffix(2) == [0x0D, 0x0A])
            bytes += chunk.count
            chunks += 1
        }
        // Whole lines, as many as fit in 10 MiB.
        #expect(bytes <= DemoShell.floodBytes)
        #expect(bytes > DemoShell.floodBytes - 200)
        #expect(shell.nextFloodChunk() == nil)
    }

    @Test func controlCStopsTheFlood() {
        var shell = DemoShell()
        _ = output(of: &shell)
        shell.handle(.command(.flood))
        _ = output(of: &shell)
        _ = shell.nextFloodChunk()
        shell.handle(.input([0x03]))
        let text = output(of: &shell)
        #expect(text.hasPrefix("^C\r\n"))
        #expect(text.contains("Stopped after 0.0 MB"))
        #expect(shell.nextFloodChunk() == nil)
    }

    /// Through the stream, as a terminal reads it: input posted on one side is answered on the
    /// other, in order.
    @Test func streamAnswersInputInOrder() async {
        let demo = TerminalDemo()
        var iterator = demo.output.makeAsyncIterator()
        let welcome = await iterator.next()
        #expect(welcome.map { String(decoding: $0, as: UTF8.self) }?.contains("demo") == true)
        demo.send(Array("si".utf8))
        demo.send(Array("ze".utf8))
        demo.resize(to: TerminalSize(columns: 50, rows: 20))
        demo.send([0x0D])
        var text = ""
        while !text.contains("50 columns") {
            guard let chunk = await iterator.next() else { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        #expect(text.hasPrefix("size\r\n50 columns, 20 rows"))
    }

    /// A terminal that detaches cancels its reading task; the demo's output then ends.
    @Test func outputEndsWhenItsTaskIsCancelled() async {
        let demo = TerminalDemo()
        let reader = Task {
            var chunks = 0
            for await _ in demo.output {
                chunks += 1
            }
            return chunks
        }
        try? await Task.sleep(for: .milliseconds(50))
        reader.cancel()
        #expect(await reader.value == 1)
    }
}
