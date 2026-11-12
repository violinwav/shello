/// A key of the Shello keyboard or of the extra keys row, as layout data (STACK section 7.5): what
/// it does, what its cap shows and what VoiceOver says, its corner symbol and its alternates. Layers
/// and rows are lists of keys, so a new layout, such as AZERTY or the Vim pad, is new data.
nonisolated public struct KeyboardKey: Hashable, Sendable {
    public var action: KeyAction
    /// What the cap shows.
    public var label: String
    /// What VoiceOver says for the key.
    public var spokenLabel: String
    /// The symbol in the cap's corner, which a flick down types.
    public var flick: String?
    /// What a long-press offers besides the key's own character, such as accented letters.
    public var alternates: [String]
    /// The key's width, in widths of a letter key.
    public var width: Double
    public var style: KeyStyle

    public init(
        _ action: KeyAction, label: String, spokenLabel: String? = nil, flick: String? = nil,
        alternates: [String] = [], width: Double = 1, style: KeyStyle = .character
    ) {
        self.action = action
        self.label = label
        self.spokenLabel = spokenLabel ?? label
        self.flick = flick
        self.alternates = alternates
        self.width = width
        self.style = style
    }

    /// Whether holding the key repeats it: Delete, Space and the arrows (README section 6).
    public var repeats: Bool {
        switch action {
        case .key(.backspace), .text(" "), .key(.up), .key(.down), .key(.left), .key(.right): true
        default: false
        }
    }

    /// Whether the key acts as soon as it is touched, rather than when the finger lifts: the
    /// modifiers, so that they can be held while another key is tapped, and the keys that repeat.
    var actsOnTouchDown: Bool {
        if case .modifier = action { return true }
        return repeats
    }
}

/// What a key does.
nonisolated public enum KeyAction: Hashable, Sendable {
    /// Types text: a character on the Shello keyboard. Shift makes a letter a capital.
    case text(String)
    /// Sends a key that is not a character, such as Esc or F5.
    case key(TerminalKey)
    /// Sends Control and a character, as the function layer's ^C does.
    case control(Character)
    /// Shift, Control or Alt.
    case modifier(Modifier)
    /// Shows another layer of the Shello keyboard.
    case layer(KeyboardLayer.Kind)
    /// The swipe key, which sends arrow keys while the user drags across it (GLOSSARY).
    case arrows
    /// Switches between the Shello keyboard and the system keyboard.
    case switchKeyboard
}

/// The keys a terminal understands that are not characters.
nonisolated public enum TerminalKey: Hashable, Sendable {
    case escape
    case tab
    case `return`
    /// Delete, the key left of Return: it deletes backwards.
    case backspace
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case insert
    /// Forward delete, Del on the function layer.
    case delete
    /// F1 to F12.
    case function(Int)
}

/// The modifier keys of the Shello keyboard and the extra keys row.
nonisolated public enum Modifier: Hashable, Sendable, CaseIterable {
    /// Shift for the letters, on the letters layer.
    case shift
    case control
    /// Alt, which sends Esc before the next key, as Option does when it is Meta.
    case alt
}

/// How a key's cap is drawn, after the UI design (docs/ui/ui_v1/canvas/Terminal.dc.html).
nonisolated public enum KeyStyle: Hashable, Sendable {
    /// A letter, digit or symbol.
    case character
    /// Space: a wide key with its name in small, dimmer text.
    case space
    /// Shift and Delete: a darker key.
    case system
    /// A key that shows another layer, or the other keyboard: a darker key with small text.
    case layer
    /// Return, the one key in the accent colour.
    case accent
    /// A function layer key with a short name, such as F5 or pgup.
    case function
    /// A Control combination of the function layer, in the accent colour.
    case shortcut
    /// A key of the extra keys row with a short name, such as esc.
    case extra
    /// A symbol on the extra keys row.
    case extraSymbol
}

/// A row of keys, left to right.
nonisolated public struct KeyboardRow: Hashable, Sendable {
    public var keys: [KeyboardKey]
    /// The space before the first key and after the last, in widths of a letter key: the design
    /// moves a shorter row of letters in by about half a key on each side.
    public var inset: Double

    public init(_ keys: [KeyboardKey], inset: Double = 0) {
        self.keys = keys
        self.inset = inset
    }
}

/// One layer of the Shello keyboard (GLOSSARY): its rows of keys, top to bottom. One layer shows at
/// a time.
nonisolated public struct KeyboardLayer: Hashable, Sendable {
    public enum Kind: Hashable, Sendable, CaseIterable {
        case letters
        case symbols
        /// F1 to F12, the navigation keys and common Control combinations.
        case function
    }

    public var kind: Kind
    public var rows: [KeyboardRow]

    public init(kind: Kind, rows: [KeyboardRow]) {
        self.kind = kind
        self.rows = rows
    }

    /// Every key of the layer, row by row.
    public var keys: [KeyboardKey] { rows.flatMap(\.keys) }
}
