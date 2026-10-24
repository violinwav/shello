import Foundation

/// The arrangement of the letters layer (GLOSSARY, Letters layout), as data: the letters of each
/// row, the symbol in each letter's corner, and the letters a long-press offers. A new layout,
/// such as AZERTY (v1), is a new value of this type.
nonisolated public struct LettersLayout: Hashable, Sendable, Identifiable {
    public enum ID: String, CaseIterable, Sendable, Identifiable {
        case qwerty
        case qwertz

        public var id: Self { self }

        public var layout: LettersLayout {
            switch self {
            case .qwerty: .qwerty
            case .qwertz: .qwertz
            }
        }
    }

    public let id: ID
    /// The layout's name, as Settings shows it.
    public let name: String
    /// The letters of each row, top to bottom.
    let rows: [String]
    /// The symbols in the letters' corners, row by row and letter by letter.
    let flicks: [String]
    /// What a long-press on a letter offers, most used first.
    let alternates: [Character: String]

    /// The UI design's letters (docs/ui/ui_v1/canvas/Terminal.dc.html), with the accented letters
    /// of Western European languages under a long-press.
    public static let qwerty = LettersLayout(
        id: .qwerty, name: "QWERTY",
        rows: ["qwertyuiop", "asdfghjkl", "zxcvbnm"],
        flicks: ["1234567890", "@#$_&-+()", "*\"':;!?"],
        alternates: [
            "a": "àáâäæãåā", "c": "çćč", "e": "èéêëēėę", "i": "îïíīįì", "l": "ł", "n": "ñń",
            "o": "ôöòóœøōõ", "s": "ßśš", "u": "ûüùúū", "y": "ÿ", "z": "žźż",
        ])

    /// German and Central European keyboards: Y and Z swap places, and the umlauts come first.
    public static let qwertz = LettersLayout(
        id: .qwertz, name: "QWERTZ",
        rows: ["qwertzuiop", "asdfghjkl", "yxcvbnm"],
        flicks: ["1234567890", "@#$_&-+()", "*\"':;!?"],
        alternates: [
            "a": "äàáâæãåā", "o": "öôòóœøōõ", "u": "üûùúū", "s": "ßśš", "e": "éèêëēėę", "c": "çćč",
            "i": "îïíīįì", "n": "ñń", "z": "žźż", "y": "ÿ", "l": "ł",
        ])

    /// The languages whose system keyboards are QWERTZ: German and its neighbours to the east.
    /// Every keyboard of Switzerland and Liechtenstein is QWERTZ too, Swiss French and Italian
    /// included.
    private static let qwertzLanguages: Set<String> = ["de", "cs", "sk", "hu", "sl", "hr", "bs", "lb", "rm"]
    private static let qwertzRegions: Set<String> = ["CH", "LI"]

    /// The layout of the first system keyboard among `languages`, the primary languages of the
    /// keyboards in the Settings app in their order (`UITextInputMode.activeInputModes`), such as
    /// "de-CH". The emoji keyboard and dictation are not languages; with no language, QWERTY.
    public static func automatic(forKeyboardLanguages languages: [String]) -> ID {
        guard let first = languages.first(where: { !["emoji", "dictation", ""].contains($0) }) else {
            return .qwerty
        }
        let locale = Locale(identifier: first)
        if let region = locale.region?.identifier, qwertzRegions.contains(region) {
            return .qwertz
        }
        if let language = locale.language.languageCode?.identifier, qwertzLanguages.contains(language) {
            return .qwertz
        }
        return .qwerty
    }
}

nonisolated extension KeyboardLayer {
    /// The letters layer in `layout`: its three rows of letters, Shift and Delete around the
    /// third, and the row with the other layers, Space and Return under them.
    public static func letters(_ layout: LettersLayout) -> KeyboardLayer {
        let longest = layout.rows.map(\.count).max() ?? 0
        var rows = zip(layout.rows, layout.flicks).map { letters, flicks in
            KeyboardRow(
                zip(letters, flicks).map { letter, flick in
                    KeyboardKey.character(
                        String(letter), flick: String(flick), alternates: layout.alternates[letter] ?? "")
                },
                // A shorter row moves in by half a key on each side, as the design's second row.
                inset: Double(longest - letters.count) / 2)
        }
        if rows.count == 3 {
            rows[2] = KeyboardRow([.shift] + rows[2].keys + [.backspace])
        }
        rows.append(
            KeyboardRow([
                .layer(.symbols), .layer(.function), .space, .character(".", flick: ","), .return,
            ]))
        return KeyboardLayer(kind: .letters, rows: rows)
    }

    /// Digits and the symbols of README section 6. The design has no < or = anywhere, so they and
    /// > sit in the corners of the parentheses and the caret, flicked down like the letters'.
    public static let symbols = KeyboardLayer(
        kind: .symbols,
        rows: [
            KeyboardRow("1234567890".map { .character(String($0)) }),
            KeyboardRow(
                [
                    .character("!"), .character("@"), .character("#"), .character("$"), .character("%"),
                    .character("^", flick: "="), .character("&"), .character("*"), .character("(", flick: "<"),
                    .character(")", flick: ">"),
                ]),
            KeyboardRow("~`|\\{}[]".map { .character(String($0)) } + [.backspace]),
            KeyboardRow([.layer(.letters), .layer(.function), .space, .character("-", flick: "_"), .return]),
        ])

    /// F1 to F12, the navigation keys and the Control combinations a shell uses most. The arrows
    /// sit beside a narrower Space, which the design does not have: the swipe key sends them too,
    /// but takes a drag or an aimed tap, which not everyone can make (WCAG 2.5.7), and Voice
    /// Control can name these.
    public static let function = KeyboardLayer(
        kind: .function,
        rows: [
            KeyboardRow((1...10).map { .function(.function($0)) }),
            KeyboardRow(
                [
                    TerminalKey.function(11), .function(12), .home, .end, .pageUp, .pageDown, .insert, .delete,
                ].map { .function($0, width: 1.25) }),
            KeyboardRow(Array("cdzlraew").map { KeyboardKey.control($0) } + [.backspace]),
            KeyboardRow(
                [KeyboardKey.layer(.letters), .layer(.symbols), .space.resized(to: 2)]
                    + [TerminalKey.left, .up, .down, .right].map { KeyboardKey.arrow($0) }
                    + [KeyboardKey.character("/", flick: "?"), .return]),
        ])

    /// The layer `kind` with the letters in `letters`.
    public static func layer(_ kind: Kind, letters: LettersLayout) -> KeyboardLayer {
        switch kind {
        case .letters: .letters(letters)
        case .symbols: .symbols
        case .function: .function
        }
    }
}

/// The extra keys row (GLOSSARY): the keys a terminal needs that the system keyboard lacks, above
/// whichever keyboard is up (README section 6).
nonisolated public enum ExtraKeys {
    /// Esc, Tab, the sticky modifiers, the swipe key and the symbols a shell uses most, from the
    /// UI design. Presets (v1) are other lists of keys.
    public static let standard: [KeyboardKey] =
        [
            KeyboardKey(.key(.escape), label: "esc", spokenLabel: String(localized: "Escape"), style: .extra),
            KeyboardKey(.key(.tab), label: "tab", spokenLabel: String(localized: "Tab"), style: .extra),
            KeyboardKey(
                .modifier(.control), label: "ctrl", spokenLabel: String(localized: "Control"), width: 8 / 7,
                style: .extra),
            KeyboardKey(.modifier(.alt), label: "alt", spokenLabel: String(localized: "Alt"), style: .extra),
            KeyboardKey(.arrows, label: "", spokenLabel: String(localized: "Swipe Key"), style: .extra),
        ]
        + "|~/-$>*".map { symbol in
            KeyboardKey(
                .text(String(symbol)), label: String(symbol), spokenLabel: KeyboardKey.spokenName(of: String(symbol)),
                width: 34 / 42, style: .extraSymbol)
        }

    /// The key that switches to the other keyboard. It stays at the end of the row, outside the
    /// part that scrolls, and says which keyboard it switches to.
    static func switchKey(toSystemKeyboard: Bool) -> KeyboardKey {
        KeyboardKey(
            .switchKeyboard, label: "",
            spokenLabel: toSystemKeyboard
                ? String(localized: "Switch to System Keyboard") : String(localized: "Switch to Shello Keyboard"),
            style: .extra)
    }
}

nonisolated extension KeyboardKey {
    /// A key that types `character`, with `flick` in its corner and `alternates` under a long-press.
    static func character(_ character: String, flick: String? = nil, alternates: String = "") -> KeyboardKey {
        KeyboardKey(
            .text(character), label: character, spokenLabel: spokenName(of: character), flick: flick,
            alternates: alternates.map(String.init))
    }

    static let shift = KeyboardKey(
        .modifier(.shift), label: "⇧", spokenLabel: String(localized: "Shift"), width: 1.45, style: .system)

    static let backspace = KeyboardKey(
        .key(.backspace), label: "⌫", spokenLabel: String(localized: "Delete"), width: 1.45, style: .system)

    static let space = KeyboardKey(
        .text(" "), label: "space", spokenLabel: String(localized: "Space"), width: 5, style: .space)

    /// The key, `width` letter keys wide.
    func resized(to width: Double) -> KeyboardKey {
        var key = self
        key.width = width
        return key
    }

    static let `return` = KeyboardKey(
        .key(.return), label: "return", spokenLabel: String(localized: "Return"), width: 2.2, style: .accent)

    /// The key that shows the layer `kind`.
    static func layer(_ kind: KeyboardLayer.Kind) -> KeyboardKey {
        switch kind {
        case .letters:
            KeyboardKey(
                .layer(kind), label: "abc", spokenLabel: String(localized: "Letters"), width: 1.25, style: .layer)
        case .symbols:
            KeyboardKey(
                .layer(kind), label: "123", spokenLabel: String(localized: "Symbols"), width: 1.25, style: .layer)
        case .function:
            KeyboardKey(
                .layer(kind), label: "fn", spokenLabel: String(localized: "Function Keys"), width: 1.25, style: .layer)
        }
    }

    /// A key of the function layer.
    static func function(_ key: TerminalKey, width: Double = 1) -> KeyboardKey {
        let (label, spoken): (String, String) =
            switch key {
            case .function(let number): ("F\(number)", "F\(number)")
            case .home: ("home", String(localized: "Home"))
            case .end: ("end", String(localized: "End"))
            case .pageUp: ("pgup", String(localized: "Page Up"))
            case .pageDown: ("pgdn", String(localized: "Page Down"))
            case .insert: ("ins", String(localized: "Insert"))
            case .delete: ("del", String(localized: "Forward Delete"))
            default: ("\(key)", "\(key)")
            }
        return KeyboardKey(.key(key), label: label, spokenLabel: spoken, width: width, style: .function)
    }

    /// An arrow key of the function layer, drawn as large as a letter.
    static func arrow(_ key: TerminalKey) -> KeyboardKey {
        let (label, spoken): (String, String) =
            switch key {
            case .left: ("←", String(localized: "Left Arrow"))
            case .up: ("↑", String(localized: "Up Arrow"))
            case .down: ("↓", String(localized: "Down Arrow"))
            default: ("→", String(localized: "Right Arrow"))
            }
        return KeyboardKey(.key(key), label: label, spokenLabel: spoken)
    }

    /// A key that sends Control and `letter`, such as ^C.
    static func control(_ letter: Character) -> KeyboardKey {
        let name = letter.uppercased()
        return KeyboardKey(
            .control(letter), label: "^\(name)", spokenLabel: String(localized: "Control-\(name)"), style: .shortcut)
    }

    /// What VoiceOver says for a symbol, which it would otherwise leave out at some punctuation
    /// settings. Letters and digits are said as they are.
    static func spokenName(of symbol: String) -> String {
        switch symbol {
        case "!": String(localized: "Exclamation Mark")
        case "\"": String(localized: "Quotation Mark")
        case "#": String(localized: "Number Sign")
        case "$": String(localized: "Dollar Sign")
        case "%": String(localized: "Percent Sign")
        case "&": String(localized: "Ampersand")
        case "'": String(localized: "Apostrophe")
        case "(": String(localized: "Left Parenthesis")
        case ")": String(localized: "Right Parenthesis")
        case "*": String(localized: "Asterisk")
        case "+": String(localized: "Plus Sign")
        case ",": String(localized: "Comma")
        case "-": String(localized: "Hyphen")
        case ".": String(localized: "Period")
        case "/": String(localized: "Slash")
        case ":": String(localized: "Colon")
        case ";": String(localized: "Semicolon")
        case "<": String(localized: "Less-Than Sign")
        case "=": String(localized: "Equals Sign")
        case ">": String(localized: "Greater-Than Sign")
        case "?": String(localized: "Question Mark")
        case "@": String(localized: "At Sign")
        case "[": String(localized: "Left Bracket")
        case "\\": String(localized: "Backslash")
        case "]": String(localized: "Right Bracket")
        case "^": String(localized: "Caret")
        case "_": String(localized: "Underscore")
        case "`": String(localized: "Grave Accent")
        case "{": String(localized: "Left Brace")
        case "|": String(localized: "Vertical Bar")
        case "}": String(localized: "Right Brace")
        case "~": String(localized: "Tilde")
        default: symbol
        }
    }

    /// Other names a symbol goes by, which Voice Control also takes, such as "Pipe" for |.
    static func otherNames(of symbol: String) -> [String] {
        switch symbol {
        case "|": [String(localized: "Pipe")]
        case "-": [String(localized: "Minus"), String(localized: "Dash")]
        case "*": [String(localized: "Star")]
        case "#": [String(localized: "Hash")]
        case ".": [String(localized: "Dot")]
        case "$": [String(localized: "Dollar")]
        case "<": [String(localized: "Less Than")]
        case ">": [String(localized: "Greater Than")]
        case "=": [String(localized: "Equals")]
        default: []
        }
    }
}
