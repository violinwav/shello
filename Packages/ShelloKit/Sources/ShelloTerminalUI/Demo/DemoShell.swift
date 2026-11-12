import Foundation
import ShelloModel

/// The terminal demo's stand-in for a shell: it shows a prompt, echoes what the user types, and
/// runs a few built-in commands that print the demo's screens. A plain state machine that turns
/// events into output; `TerminalDemo` drives it.
nonisolated struct DemoShell {
    enum Event: Sendable {
        /// What the terminal sent: keys, pastes and mouse reports.
        case input([UInt8])
        case resize(TerminalSize)
        /// A command from the Demo menu, run as if typed at the prompt.
        case command(DemoCommand)
    }

    private enum Mode {
        case prompt
        /// A full-screen screen on the alternate screen; q goes back.
        case alternateScreen
        /// Mouse reporting on; each click is printed, q stops.
        case mouse
        /// The 10 MB output test.
        case flood(Flood)
    }

    private struct Flood {
        /// The bytes printed so far.
        var printed = 0
        /// The next line, counting from the first.
        var line = 0
        /// Whether typing was echoed after the last chunk, on a line of its own that has no end.
        var hasEchoAfterLastChunk = false
        let started: ContinuousClock.Instant
    }

    /// How much the output test prints at most: the whole lines that fit in 10 MiB.
    static let floodBytes = 10 * 1_048_576
    /// The most bytes in a chunk of the output test, which the terminal parses before it asks for
    /// the next: the user's input is never more than one chunk behind.
    static let floodChunkBytes = 16 * 1024
    /// The output test's lines, made once and repeated, so that making them costs nothing next to
    /// the terminal's work.
    private static let floodLines = (0..<1000).map { Array(DemoScreens.floodLine($0).utf8) }

    private(set) var size = TerminalSize(columns: 80, rows: 24)
    private var mode = Mode.prompt
    /// The line being typed. Pasted line breaks stay in it until Return runs it.
    private var line = ""
    /// Whether the shell asked the terminal for bracketed paste.
    private var bracketedPaste = false
    /// Between the markers of a bracketed paste, where a line break does not run the line.
    private var isInPaste = false
    /// Input bytes of an escape sequence or a UTF-8 character not complete yet.
    private var pendingInput: [UInt8] = []
    private var output: [UInt8] = []
    private let clock = ContinuousClock()

    init() {
        write(DemoScreens.welcome() + DemoScreens.prompt)
    }

    /// Output not taken yet: echo and the output of commands, which go before the output test's.
    mutating func takeOutput() -> [UInt8]? {
        guard !output.isEmpty else { return nil }
        defer { output = [] }
        return output
    }

    /// The next chunk of the output test, while it runs. Ends it with a summary and the prompt.
    ///
    /// A chunk holds whole lines. Echo goes out between chunks, and a chunk that ended inside a
    /// line could end inside an escape sequence, which the echo would break.
    mutating func nextFloodChunk() -> [UInt8]? {
        guard case .flood(var flood) = mode else { return nil }
        var chunk: [UInt8] = []
        chunk.reserveCapacity(Self.floodChunkBytes)
        while true {
            let next = Self.floodLines[flood.line % Self.floodLines.count]
            guard chunk.count + next.count <= Self.floodChunkBytes,
                flood.printed + chunk.count + next.count <= Self.floodBytes
            else { break }
            chunk += next
            flood.line += 1
        }
        guard !chunk.isEmpty else {
            finishFlood(flood, stopped: false)
            return takeOutput()
        }
        flood.printed += chunk.count
        flood.hasEchoAfterLastChunk = false
        mode = .flood(flood)
        return chunk
    }

    mutating func handle(_ event: Event) {
        switch event {
        case .input(let bytes): input(bytes)
        case .resize(let size): self.size = size
        case .command(let command): run(command)
        }
    }

    // MARK: - Input

    private mutating func input(_ bytes: [UInt8]) {
        pendingInput += bytes
        var index = 0
        while index < pendingInput.count {
            guard let length = Self.lengthOfInput(at: index, in: pendingInput) else { break }
            let unit = Array(pendingInput[index..<(index + length)])
            index += length
            key(unit)
        }
        pendingInput.removeFirst(index)
    }

    /// The length of the key, escape sequence or UTF-8 character at `index`, or nil while it is
    /// incomplete.
    private static func lengthOfInput(at index: Int, in bytes: [UInt8]) -> Int? {
        let first = bytes[index]
        if first == 0x1B {
            guard index + 1 < bytes.count else { return nil }
            guard bytes[index + 1] == UInt8(ascii: "[") || bytes[index + 1] == UInt8(ascii: "O") else {
                // Meta and a key: Esc then the key, taken one at a time.
                return 1
            }
            var end = index + 2
            while end < bytes.count {
                if (0x40...0x7E).contains(bytes[end]) { return end - index + 1 }
                end += 1
            }
            return nil
        }
        let length =
            switch first {
            case 0xC0...0xDF: 2
            case 0xE0...0xEF: 3
            case 0xF0...0xF7: 4
            default: 1
            }
        return index + length <= bytes.count ? length : nil
    }

    private mutating func key(_ unit: [UInt8]) {
        if unit.first == 0x1B, unit.count > 1 {
            escapeSequence(unit)
            return
        }
        switch mode {
        case .alternateScreen:
            if unit == [UInt8(ascii: "q")] {
                write(DemoScreens.leaveAlternateScreen)
                mode = .prompt
                write(DemoScreens.prompt + line)
            }
        case .mouse:
            if unit == [UInt8(ascii: "q")] {
                write(DemoScreens.mouseOff)
                mode = .prompt
                write(DemoScreens.prompt + line)
            }
        case .flood(var flood):
            // Control-C stops the test. Anything else is typed ahead, and echoed at once: input is
            // never queued behind output.
            if unit == [0x03] {
                flood.hasEchoAfterLastChunk = false
                write("^C\r\n")
                finishFlood(flood, stopped: true)
            } else {
                edit(unit)
                flood.hasEchoAfterLastChunk = true
                mode = .flood(flood)
            }
        case .prompt:
            switch unit {
            case [0x0D] where !isInPaste, [0x0A] where !isInPaste: returnKey()
            case [0x03]:
                line = ""
                write("^C\r\n" + DemoScreens.prompt)
            case [0x0C]:
                write("\u{1B}[H\u{1B}[2J" + DemoScreens.prompt + line)
            default: edit(unit)
            }
        }
    }

    /// Typing at the prompt: printable characters are added and echoed, Delete removes the last.
    private mutating func edit(_ unit: [UInt8]) {
        switch unit {
        case [0x7F], [0x08]:
            guard let last = line.last, last != "\n" else { return }
            line.removeLast()
            write("\u{8} \u{8}")
        case [0x0D], [0x0A]:
            // A line break inside a bracketed paste is kept, not run.
            line += "\n"
            write("\r\n")
        default:
            guard let first = unit.first, first >= 0x20 else { return }
            let text = String(decoding: unit, as: UTF8.self)
            line += text
            write(text)
        }
    }

    private mutating func escapeSequence(_ sequence: [UInt8]) {
        let body = String(decoding: sequence.dropFirst(2), as: UTF8.self)
        switch body {
        case "200~":
            // Bracketed paste: the text up to the end marker arrives as typed, line breaks kept.
            isInPaste = true
        case "201~":
            isInPaste = false
        default:
            // An SGR mouse report: CSI < button ; column ; row M, or m when released.
            if case .mouse = mode, body.hasPrefix("<"), body.hasSuffix("M") {
                let fields = body.dropFirst().dropLast().split(separator: ";").compactMap { Int($0) }
                if fields.count == 3, fields[0] & 0b0110_0011 == 0 {
                    write(DemoScreens.click(column: fields[1], row: fields[2]))
                }
            }
        }
    }

    private mutating func returnKey() {
        write("\r\n")
        let commands = line.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        line = ""
        for command in commands where !command.isEmpty {
            if let known = DemoCommand(rawValue: command) {
                execute(known)
            } else {
                write(DemoScreens.commandNotFound(command))
            }
            // A command that changed mode takes over until it ends.
            guard case .prompt = mode else { return }
        }
        write(DemoScreens.prompt)
    }

    // MARK: - Commands

    /// Runs a command from the Demo menu as if it was typed: what was on the prompt line is
    /// dropped, and a screen still up is left first.
    private mutating func run(_ command: DemoCommand) {
        switch mode {
        case .alternateScreen: write(DemoScreens.leaveAlternateScreen + DemoScreens.prompt)
        case .mouse: write(DemoScreens.mouseOff + DemoScreens.prompt)
        case .flood(var flood):
            flood.hasEchoAfterLastChunk = false
            write("^C\r\n")
            finishFlood(flood, stopped: true)
        case .prompt: break
        }
        mode = .prompt
        if !line.isEmpty {
            write(String(repeating: "\u{8} \u{8}", count: line.count))
            line = ""
        }
        line = command.rawValue
        write(command.rawValue)
        returnKey()
    }

    private mutating func execute(_ command: DemoCommand) {
        switch command {
        case .help: write(DemoScreens.help())
        case .colors: write(DemoScreens.colors(columns: size.columns))
        case .attributes: write(DemoScreens.attributes())
        case .unicode: write(DemoScreens.unicode())
        case .alternate:
            write(DemoScreens.alternateScreen(size: (size.columns, size.rows)))
            mode = .alternateScreen
        case .mouse:
            write(DemoScreens.mouseOn + DemoScreens.mouseHelp())
            mode = .mouse
        case .bell: write("\u{7}")
        case .flood: mode = .flood(Flood(started: clock.now))
        case .paste:
            bracketedPaste.toggle()
            write(
                (bracketedPaste ? DemoScreens.bracketedPasteOn : DemoScreens.bracketedPasteOff)
                    + DemoScreens.bracketedPaste(isOn: bracketedPaste))
        case .size: write(DemoScreens.size(columns: size.columns, rows: size.rows))
        case .clear: write("\u{1B}[H\u{1B}[2J")
        }
    }

    private mutating func finishFlood(_ flood: Flood, stopped: Bool) {
        mode = .prompt
        // The test's chunks end with their lines; typing echoed after the last one does not.
        write(
            (flood.hasEchoAfterLastChunk ? "\r\n" : "")
                + DemoScreens.floodSummary(
                    bytes: flood.printed, duration: clock.now - flood.started, stopped: stopped)
                + DemoScreens.prompt + line)
    }

    private mutating func write(_ text: String) {
        output += text.utf8
    }
}

/// The terminal demo's commands, which the user types at its prompt or picks in the Demo menu.
nonisolated public enum DemoCommand: String, CaseIterable, Sendable {
    case help
    case colors
    case attributes
    case unicode
    case alternate
    case mouse
    case bell
    case flood
    case paste
    case size
    case clear
}
