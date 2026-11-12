import Foundation

/// The terminal demo's scripted output: the screens that exercise colours, text attributes,
/// Unicode widths and the alternate screen, the lines of the 10 MB output test, and its messages.
/// Each screen fits the width it is given, from 40 columns up.
nonisolated enum DemoScreens {
    static let prompt = "\u{1B}[32mdemo\u{1B}[0m$ "

    static func welcome() -> String {
        lines([
            "\u{1B}[1mShello terminal demo\u{1B}[0m",
            "A stand-in for a server, on this device.",
            "Nothing you type leaves it.",
            "Type \u{1B}[1mhelp\u{1B}[0m, or use the Demo menu.",
            "",
        ])
    }

    static func help() -> String {
        lines(
            [
                "colors      16, 256 and 24-bit colors",
                "attributes  bold, italic, underline and more",
                "unicode     wide characters, emoji, marks",
                "alternate   a full-screen program",
                "mouse       report taps as mouse clicks",
                "bell        ring the bell",
                "flood       print 10 MB as fast as it can",
                "paste       turn bracketed paste on or off",
                "size        show the terminal's size",
                "clear       clear the screen",
            ].map { "  " + $0 })
    }

    /// The 16 ANSI colours as foreground and background, the 256-colour palette and 24-bit
    /// gradients.
    static func colors(columns: Int) -> String {
        var text = heading("16 colors")
        for row in [0, 8] {
            text += "  "
            for color in row..<(row + 8) {
                let foreground = color == 0 ? 15 : 0
                text += "\u{1B}[48;5;\(color);38;5;\(foreground)m\(pad(color, 3)) \u{1B}[0m"
            }
            text += "\r\n"
        }
        text += "  "
        for color in 0..<8 {
            text += "\u{1B}[\(30 + color)m\u{2588}\u{1B}[\(90 + color)m\u{2588}\u{1B}[0m "
        }
        text += "\r\n"

        text += heading("256 colors")
        // The 6×6×6 cube as six rows of 36, or twelve rows of 18 on a narrow screen.
        let perRow = columns >= 40 ? 36 : 18
        for start in stride(from: 16, to: 232, by: perRow) {
            text += "  "
            for color in start..<(start + perRow) {
                text += "\u{1B}[48;5;\(color)m \u{1B}[0m"
            }
            text += "\r\n"
        }
        text += "  "
        for color in 232..<256 {
            text += "\u{1B}[48;5;\(color)m \u{1B}[0m"
        }
        text += "\r\n"

        text += heading("24-bit color")
        let width = max(8, min(columns - 4, 72))
        for gradient in [rainbow, { (t: Double) in (t, 0.2, 1 - t) }, { (t: Double) in (t, t, t) }] {
            text += "  "
            for step in 0..<width {
                let (red, green, blue) = gradient(Double(step) / Double(width - 1))
                text += "\u{1B}[48;2;\(byte(red));\(byte(green));\(byte(blue))m \u{1B}[0m"
            }
            text += "\r\n"
        }
        return text
    }

    /// The SGR text attributes, alone and combined. Concealed text (SGR 8) is left out: SwiftTerm
    /// 1.99 draws it as plain text.
    static func attributes() -> String {
        heading("Text attributes")
            + lines(
                [
                    "\u{1B}[1mBold\u{1B}[0m  \u{1B}[2mDim\u{1B}[0m  \u{1B}[3mItalic\u{1B}[0m  "
                        + "\u{1B}[1;3mBold italic\u{1B}[0m",
                    "\u{1B}[4mUnderline\u{1B}[0m  \u{1B}[21mDouble\u{1B}[0m  \u{1B}[4:3mCurly\u{1B}[0m  "
                        + "\u{1B}[4:4mDotted\u{1B}[0m",
                    "\u{1B}[4:5mDashed\u{1B}[0m  \u{1B}[4:3;58;5;1mColored curly\u{1B}[0m",
                    "\u{1B}[9mStrikethrough\u{1B}[0m  \u{1B}[5mBlink\u{1B}[0m",
                    "\u{1B}[7mInverse\u{1B}[0m  \u{1B}[1;4;31mBold red underline\u{1B}[0m",
                    "\u{1B}[38;2;232;196;107;48;2;43;46;51m24-bit text on a 24-bit background\u{1B}[0m",
                ].map { "  " + $0 })
    }

    /// Characters of every width. Each line closes with a bar in the same column, which only
    /// lines up if every character takes as many columns as xterm gives it (README section 5).
    static func unicode() -> String {
        heading("Unicode widths")
            + lines(
                [
                    "ASCII     |abcdefghijkl|",
                    // CJK ideographs, kana and fullwidth forms take two columns.
                    "Wide      |漢字かなカナ|",
                    // Emoji take two columns; a flag is two regional indicators of one column each.
                    "Emoji     |🙂🚀🐧🦀🎉🇨🇭|",
                    // Combining marks take none: each letter here is two code points.
                    "Combining |e\u{301}n\u{303}u\u{308}a\u{30A}o\u{302}i\u{308}c\u{327}abcde|",
                    "Box       |┌──┬──┐ ╭─╮ |",
                    "          |└──┴──┘ ╰─╯ |",
                    "Blocks    |░▒▓█▀▄▌▐▖▗▘▙|",
                ].map { "  " + $0 })
    }

    /// Switches to the alternate screen, as a full-screen program does, and draws a frame around
    /// it. The normal screen and its scrollback come back unchanged with `leaveAlternateScreen`.
    static func alternateScreen(size: (columns: Int, rows: Int)) -> String {
        let columns = max(size.columns, 20)
        let rows = max(size.rows, 6)
        var text = "\u{1B}[?1049h\u{1B}[H\u{1B}[2J"
        text += "\u{1B}[1;1H┌" + String(repeating: "─", count: columns - 2) + "┐"
        for row in 2..<rows {
            text += "\u{1B}[\(row);1H│\u{1B}[\(row);\(columns)H│"
        }
        text += "\u{1B}[\(rows);1H└" + String(repeating: "─", count: columns - 2) + "┘"
        let messages = ["Alternate screen", "Your scrollback is safe.", "Press q to go back."]
        for (index, message) in messages.enumerated() {
            let row = rows / 2 - 1 + index
            let column = max(2, (columns - message.count) / 2 + 1)
            text += "\u{1B}[\(row);\(column)H" + (index == 0 ? "\u{1B}[1m\(message)\u{1B}[0m" : message)
        }
        return text
    }

    static let leaveAlternateScreen = "\u{1B}[?1049l"

    /// SGR mouse reporting on (modes 1000 and 1006), as a program that takes clicks turns it on.
    static let mouseOn = "\u{1B}[?1000h\u{1B}[?1006h"
    static let mouseOff = "\u{1B}[?1006l\u{1B}[?1000l"

    static func mouseHelp() -> String {
        lines(["Mouse reporting is on: each tap is a click.", "Press q to stop."])
    }

    static func click(column: Int, row: Int) -> String {
        lines(["Click at column \(column), row \(row)"])
    }

    static let bracketedPasteOn = "\u{1B}[?2004h"
    static let bracketedPasteOff = "\u{1B}[?2004l"

    /// One line of the 10 MB output test: a log line with a few colours, as servers print them.
    static func floodLine(_ number: Int) -> String {
        let levels = ["\u{1B}[32mINFO \u{1B}[0m", "\u{1B}[33mWARN \u{1B}[0m", "\u{1B}[36mDEBUG\u{1B}[0m"]
        let paths = ["/v1/jobs", "/v1/hosts/42", "/health", "/v1/keys?page=3"]
        let seconds = number % 86_400
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        return "\u{1B}[2m\(time).\(pad(number % 1000, 3, zero: true))\u{1B}[0m \(levels[number % 3]) "
            + "worker-\(number % 8) GET \(paths[number % 4]) 200 \(number % 97)ms req=\(number)\r\n"
    }

    static func floodSummary(bytes: Int, duration: Duration, stopped: Bool) -> String {
        let megabytes = Double(bytes) / 1_048_576
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let rate = seconds > 0 ? megabytes / seconds : 0
        let verb = stopped ? "Stopped after" : "Printed"
        return lines([
            String(format: "\(verb) %.1f MB in %.2f s, %.1f MB/s", megabytes, seconds, rate)
        ])
    }

    static func commandNotFound(_ command: String) -> String {
        lines(["demo: command not found: \(command)"])
    }

    static func size(columns: Int, rows: Int) -> String {
        lines(["\(columns) columns, \(rows) rows"])
    }

    static func bracketedPaste(isOn: Bool) -> String {
        lines([isOn ? "Bracketed paste is on." : "Bracketed paste is off: pastes of more lines ask first."])
    }

    // MARK: - Helpers

    private static func heading(_ title: String) -> String {
        "\u{1B}[1;4m\(title)\u{1B}[0m\r\n"
    }

    /// Lines of text, each ended for the terminal with CR LF.
    private static func lines(_ lines: [String]) -> String {
        lines.map { $0 + "\r\n" }.joined()
    }

    private static func pad(_ number: Int, _ width: Int, zero: Bool = false) -> String {
        let digits = String(number)
        return String(repeating: zero ? "0" : " ", count: max(0, width - digits.count)) + digits
    }

    private static func byte(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 255).rounded())
    }

    /// Hue from red round to red, full saturation.
    private static func rainbow(_ position: Double) -> (Double, Double, Double) {
        let hue = position * 6
        let rising = hue - hue.rounded(.down)
        switch Int(hue) % 6 {
        case 0: return (1, rising, 0)
        case 1: return (1 - rising, 1, 0)
        case 2: return (0, 1, rising)
        case 3: return (0, 1 - rising, 1)
        case 4: return (rising, 0, 1)
        default: return (1, 0, 1 - rising)
        }
    }
}
