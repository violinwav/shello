import SwiftTerm

/// The modifiers on a key press: the sticky Control and Alt of the extra keys row, and Shift.
nonisolated public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let alt = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)

    /// xterm's modifier parameter: 1, plus 1 for Shift, 2 for Alt and 4 for Control.
    var parameter: Int { rawValue + 1 }
}

/// What a key press sends.
nonisolated enum KeyOutput: Equatable {
    case bytes([UInt8])
    /// An arrow, Home or End without modifiers. Its bytes depend on the cursor key mode the program
    /// chose (DECCKM), which the terminal view knows: it sends the key itself.
    case cursor(TerminalKey)
    /// PgUp or PgDn without modifiers. The terminal view handles it as for a hardware keyboard: a
    /// program on the alternate screen gets the key, and a shell's scrollback moves a page.
    case page(TerminalKey)
}

/// The bytes a key sends: what SwiftTerm sends for the same key on a hardware keyboard, so that the
/// Shello keyboard, the extra keys row, the system keyboard and a hardware keyboard all agree. The
/// sequences come from SwiftTerm's `EscapeSequences`; a modified key gets xterm's modifier
/// parameter, as SwiftTerm's encoder gives it; Control turns a character into its control code
/// with xterm's table, and Alt sends Esc first, as Option does when it is Meta (README section 5).
nonisolated enum KeyEncoder {
    /// The output of `key` with `modifiers`. `backspaceSendsControlH` follows the terminal's setting
    /// of the same name.
    static func output(
        for key: TerminalKey, modifiers: KeyModifiers = [], backspaceSendsControlH: Bool = false
    ) -> KeyOutput {
        switch key {
        case .escape:
            return .bytes(altPrefix(modifiers) + EscapeSequences.cmdEsc)
        case .return:
            return .bytes(altPrefix(modifiers) + EscapeSequences.cmdRet)
        case .tab:
            let tab = modifiers.contains(.shift) ? EscapeSequences.cmdBackTab : EscapeSequences.cmdTab
            return .bytes(altPrefix(modifiers) + tab)
        case .backspace:
            // Control-Delete is Control-H, the other code for backspace.
            let backspace =
                modifiers.contains(.control) || backspaceSendsControlH ? [controlH] : EscapeSequences.cmdDel
            return .bytes(altPrefix(modifiers) + backspace)
        case .up, .down, .left, .right, .home, .end:
            guard !modifiers.isEmpty, let final = cursorFinal(key) else { return .cursor(key) }
            return .bytes(csi("1;\(modifiers.parameter)\(final)"))
        case .pageUp:
            return modifiers.isEmpty ? .page(key) : .bytes(tilde(5, modifiers))
        case .pageDown:
            return modifiers.isEmpty ? .page(key) : .bytes(tilde(6, modifiers))
        case .insert:
            return .bytes(modifiers.isEmpty ? EscapeSequences.cmdInsert : tilde(2, modifiers))
        case .delete:
            return .bytes(modifiers.isEmpty ? EscapeSequences.cmdDelKey : tilde(3, modifiers))
        case .function(let number):
            guard EscapeSequences.cmdF.indices.contains(number - 1) else { return .bytes([]) }
            if modifiers.isEmpty {
                return .bytes(EscapeSequences.cmdF[number - 1])
            }
            // F1 to F4 end in P to S, the others in a tilde after their number.
            if number <= 4 {
                return .bytes(csi("1;\(modifiers.parameter)\(["P", "Q", "R", "S"][number - 1])"))
            }
            return .bytes(tilde([15, 17, 18, 19, 20, 21, 23, 24][number - 5], modifiers))
        }
    }

    /// The bytes for typing `text`, already in capitals if Shift made it so, with Control and Alt
    /// from `modifiers`. Control applies to a single character with a control code; any other text
    /// goes as it is.
    static func bytes(typing text: String, modifiers: KeyModifiers = []) -> [UInt8] {
        if modifiers.contains(.control), text.count == 1, let character = text.first,
            let code = controlCode(for: character)
        {
            return altPrefix(modifiers) + [code]
        }
        return altPrefix(modifiers) + Array(text.utf8)
    }

    /// The control code xterm sends for Control and `character`, or nil for a character without
    /// one, which Control leaves as it is. Letters are the same in either case; the digits 2 to 8
    /// stand for the symbols above them on a US keyboard.
    static func controlCode(for character: Character) -> UInt8? {
        if let ascii = character.asciiValue, character.isLetter {
            return ascii & 0x1F
        }
        switch character {
        case "@", " ", "2": return 0x00
        case "[", "3": return 0x1B
        case "\\", "4": return 0x1C
        case "]", "5": return 0x1D
        case "^", "6", "~": return 0x1E
        case "_", "7", "/": return 0x1F
        case "?", "8": return 0x7F
        default: return nil
        }
    }

    private static let escape: UInt8 = 0x1B
    private static let controlH: UInt8 = 0x08

    /// Esc, before a key pressed with Alt.
    private static func altPrefix(_ modifiers: KeyModifiers) -> [UInt8] {
        modifiers.contains(.alt) ? [escape] : []
    }

    private static func csi(_ body: String) -> [UInt8] {
        [escape, UInt8(ascii: "[")] + Array(body.utf8)
    }

    /// A key that ends in a tilde after its number, such as PgUp, `CSI 5 ; m ~` with modifiers.
    private static func tilde(_ number: Int, _ modifiers: KeyModifiers) -> [UInt8] {
        csi("\(number);\(modifiers.parameter)~")
    }

    /// The final letter of a cursor key's sequence.
    private static func cursorFinal(_ key: TerminalKey) -> String? {
        switch key {
        case .up: "A"
        case .down: "B"
        case .right: "C"
        case .left: "D"
        case .home: "H"
        case .end: "F"
        default: nil
        }
    }
}
