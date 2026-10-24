import QuartzCore
import UIKit
import os

/// The Shello keyboard of one terminal (README section 6): which layer shows, Shift and the sticky
/// Control and Alt, whether the system keyboard shows in its place, and what each key sends. It owns
/// the two views the terminal shows: the keyboard itself, the terminal's input view, and the extra
/// keys row, its input accessory view, above either keyboard.
///
/// Keys go only to `terminal`, the terminal this keyboard belongs to, which is the active tab's
/// while the keyboard shows. What the user types is never logged: the signposts time keys without
/// saying which.
final class ShelloKeyboard {
    weak var terminal: TerminalHostView?
    let theme: TerminalTheme
    let typeface: TerminalTypeface
    let palette: KeyboardPalette
    var preferences: KeyboardPreferences {
        didSet { preferencesChanged(from: oldValue) }
    }
    /// Reports Control and Alt as they change, for the badge over the terminal.
    var onModifiersChange: (ArmedModifiers) -> Void = { _ in }
    /// The haptics and clicks, made with the first key: tied to the terminal, which is in a window
    /// whichever keyboard shows, where the Shello keyboard is not while the system keyboard shows.
    lazy var feedback: KeyboardFeedback = {
        let view: UIView = terminal ?? keyboardView
        return .system(for: view)
    }()

    private(set) var letters: LettersLayout
    private(set) var layer: KeyboardLayer
    private(set) var shift = StickyModifier()
    private(set) var control = StickyModifier()
    private(set) var alt = StickyModifier()
    /// Whether the system keyboard shows in place of the Shello keyboard.
    private(set) var usesSystemKeyboard = false
    private let keyboardLanguages: @MainActor () -> [String]
    private var publishedModifiers = ArmedModifiers()
    /// Whether the swipe key's drag has sent an arrow yet: its first arrow taps, the others do not.
    private var swipeHasSent = false
    /// Whether a key went to the terminal since a modifier was last touched: a modifier held for
    /// a key, on the other keyboard too, does not lock as the finger lifts.
    private var keyWentSinceModifier = false

    private(set) lazy var keyboardView = ShelloKeyboardView(keyboard: self)
    private(set) lazy var extraKeysRow = ExtraKeysRow(keyboard: self)

    init(
        theme: TerminalTheme, typeface: TerminalTypeface, preferences: KeyboardPreferences,
        keyboardLanguages: @escaping @MainActor () -> [String] = KeyboardLanguages.current
    ) {
        self.theme = theme
        self.typeface = typeface
        self.preferences = preferences
        self.keyboardLanguages = keyboardLanguages
        palette = .forTheme(theme)
        letters = Self.letters(for: preferences, languages: keyboardLanguages)
        layer = .letters(letters)
    }

    /// The input view for the keyboard that shows: the Shello keyboard, or nil for the system's.
    var inputView: UIView? {
        usesSystemKeyboard ? nil : keyboardView
    }

    /// Control and Alt, as they are on.
    var heldModifiers: KeyModifiers {
        var modifiers: KeyModifiers = []
        if control.isActive { modifiers.insert(.control) }
        if alt.isActive { modifiers.insert(.alt) }
        return modifiers
    }

    func state(of modifier: Modifier) -> StickyModifier.State {
        switch modifier {
        case .shift: shift.state
        case .control: control.state
        case .alt: alt.state
        }
    }

    // MARK: - Keys

    /// What the keyboards' touches do.
    func handle(_ event: KeyTouches.Event) {
        switch event {
        case .touchDown(let key):
            if key.action == .arrows {
                swipeHasSent = false
            }
            feedback.prepare()
        case .press(let key, let text, let isRepeat, let time):
            press(key, text: text, isRepeat: isRepeat, at: time)
        case .arrow(let direction, let time):
            send(KeyEncoder.output(for: direction.key, modifiers: heldModifiers), at: time)
            if !swipeHasSent {
                swipeHasSent = true
                tap()
            }
        case .swipeEnded:
            // Control and Alt held for the whole drag, such as Control and the arrows to move by
            // words; they let go once it ends, if it sent anything.
            if swipeHasSent {
                useModifiers()
            }
            stateChanged()
        case .lock(let key, _):
            // Only a press that armed the modifier, and was not used, locks it: a long press that
            // turned it off, as a tap does, leaves it off.
            guard case .modifier(let modifier) = key.action, state(of: modifier) == .armed, !keyWentSinceModifier
            else { return }
            setLocked(modifier, true)
            tap()
        }
    }

    /// Presses `key`, at `time` on the clock of `CACurrentMediaTime()`: types it, or `text` in
    /// its place for a flick or an alternate, or switches what it switches. The key's bytes go
    /// first, then its haptic tap and click, and then the keys are drawn again. A repeat neither
    /// taps nor clicks again.
    func press(
        _ key: KeyboardKey, text: String? = nil, isRepeat: Bool = false, at time: TimeInterval = CACurrentMediaTime()
    ) {
        // The swipe key sends as it is touched, and VoiceOver uses its actions: activating it
        // does nothing, so it does not tap or click either.
        guard key.action != .arrows else { return }
        defer {
            if !isRepeat {
                tap()
            }
            stateChanged()
        }
        switch key.action {
        case .text(let own):
            send(.bytes(KeyEncoder.bytes(typing: shifted(text ?? own), modifiers: heldModifiers)), at: time)
            shift.use()
            useModifiers()
        case .key(let terminalKey):
            let backspaceSendsControlH = terminal?.backspaceSendsControlH ?? false
            send(
                KeyEncoder.output(
                    for: terminalKey, modifiers: heldModifiers, backspaceSendsControlH: backspaceSendsControlH),
                at: time)
            useModifiers()
        case .control(let character):
            send(
                .bytes(KeyEncoder.bytes(typing: String(character), modifiers: heldModifiers.union(.control))), at: time)
            useModifiers()
        case .modifier(let modifier):
            switch modifier {
            case .shift: shift.tap(at: time)
            case .control: control.tap(at: time)
            case .alt: alt.tap(at: time)
            }
            keyWentSinceModifier = false
            announceState(of: modifier)
        case .layer(let kind):
            show(kind)
        case .arrows:
            break
        case .switchKeyboard:
            switchKeyboard()
        }
    }

    /// Locks `modifier`, or turns it off, as its VoiceOver action and a long hold do.
    func setLocked(_ modifier: Modifier, _ locked: Bool) {
        switch modifier {
        case .shift: shift.set(locked: locked)
        case .control: control.set(locked: locked)
        case .alt: alt.set(locked: locked)
        }
        announceState(of: modifier)
        stateChanged()
    }

    /// Sends one arrow, as the swipe key's actions do for VoiceOver.
    func sendArrow(_ direction: SwipeKey.Direction) {
        send(KeyEncoder.output(for: direction.key, modifiers: heldModifiers), at: CACurrentMediaTime())
        tap()
        useModifiers()
        stateChanged()
    }

    /// The system keyboard typed `text`. With Control or Alt on, the keyboard sends the key with
    /// them, as it would its own, and returns true; otherwise the terminal types the text itself.
    /// Text of more than one character, such as dictation, is not a key, so it goes as it is.
    func typeFromSystemKeyboard(_ text: String) -> Bool {
        let modifiers = heldModifiers
        guard !modifiers.isEmpty, text.count == 1 else { return false }
        let now = CACurrentMediaTime()
        switch text {
        case "\n", "\r", "\r\n": send(KeyEncoder.output(for: .return, modifiers: modifiers), at: now)
        case "\t": send(KeyEncoder.output(for: .tab, modifiers: modifiers), at: now)
        default: send(.bytes(KeyEncoder.bytes(typing: text, modifiers: modifiers)), at: now)
        }
        useModifiers()
        stateChanged()
        return true
    }

    /// The system keyboard's Delete, with Control or Alt on: Alt-Delete deletes a word in a shell.
    func deleteBackwardFromSystemKeyboard() -> Bool {
        let modifiers = heldModifiers
        guard !modifiers.isEmpty else { return false }
        let backspaceSendsControlH = terminal?.backspaceSendsControlH ?? false
        send(
            KeyEncoder.output(for: .backspace, modifiers: modifiers, backspaceSendsControlH: backspaceSendsControlH),
            at: CACurrentMediaTime())
        useModifiers()
        stateChanged()
        return true
    }

    /// `text` as Shift makes it: a capital for a single letter. A letter whose capital is two
    /// letters, as ß's is, stays as it is.
    func shifted(_ text: String) -> String {
        guard shift.isActive, text.count == 1, text.first?.isLetter == true else { return text }
        let capital = text.uppercased()
        return capital.count == 1 ? capital : text
    }

    /// Shows the layer `kind`. VoiceOver moves to the key where the pressed one was, then says
    /// which layer shows: that key need not lead back.
    func show(_ kind: KeyboardLayer.Kind) {
        guard kind != layer.kind else { return }
        layer = .layer(kind, letters: letters)
        keyboardView.layerChanged()
        if feedback.isVoiceOverRunning() {
            feedback.announce(KeyboardKey.layer(kind).spokenLabel)
        }
    }

    /// Shows the system keyboard in place of the Shello keyboard, or the Shello keyboard again.
    func switchKeyboard() {
        usesSystemKeyboard.toggle()
        terminal?.keyboardSwitched()
    }

    /// Hands `output` to the terminal, which sends it to its stream at once. The signpost interval
    /// "Key" runs from here to the stream, and says how long the touch took to get here (README
    /// section 16's budget: keystroke to network send in 10 ms).
    private func send(_ output: KeyOutput, at time: TimeInterval) {
        keyWentSinceModifier = true
        guard let terminal else { return }
        let signposter = TerminalSignposts.signposter
        let delay = max(CACurrentMediaTime() - time, 0) * 1000
        let interval = signposter.beginInterval(
            "Key", id: signposter.makeSignpostID(), "\(delay, format: .fixed(precision: 2)) ms after the touch")
        switch output {
        case .bytes(let bytes):
            terminal.send(bytes)
        case .cursor(let key):
            switch key {
            case .up: terminal.sendKeyUp()
            case .down: terminal.sendKeyDown()
            case .left: terminal.sendKeyLeft()
            case .right: terminal.sendKeyRight()
            case .home: terminal.sendKeyHome()
            default: terminal.sendKeyEnd()
            }
        case .page(let key):
            if key == .pageUp {
                terminal.pageUp()
            } else {
                terminal.pageDown()
            }
        }
        signposter.endInterval("Key", interval)
    }

    /// The haptic tap, if the user wants it, and the keyboard click.
    private func tap() {
        if preferences.haptics {
            feedback.haptic()
        }
        feedback.click()
    }

    /// Control and Alt let go after a key, unless they are locked.
    private func useModifiers() {
        control.use()
        alt.use()
    }

    /// VoiceOver says a modifier's new state, which its key only shows.
    private func announceState(of modifier: Modifier) {
        guard feedback.isVoiceOverRunning() else { return }
        let value = Self.spokenState(of: modifier, state(of: modifier)) ?? String(localized: "Off")
        feedback.announce("\(Self.spokenName(of: modifier)), \(value)")
    }

    private static func spokenName(of modifier: Modifier) -> String {
        switch modifier {
        case .shift: String(localized: "Shift")
        case .control: String(localized: "Control")
        case .alt: String(localized: "Alt")
        }
    }

    /// What the keys show besides themselves.
    private struct Looks: Equatable {
        var shift: StickyModifier.State
        var control: StickyModifier.State
        var alt: StickyModifier.State
        var usesSystemKeyboard: Bool
    }

    private var drawnLooks: Looks?

    /// Draws the keys again if what they show changed, which most keys do not change, so that the
    /// next key does not wait for it; and reports Control and Alt if they changed.
    private func stateChanged() {
        let looks = Looks(
            shift: shift.state, control: control.state, alt: alt.state, usesSystemKeyboard: usesSystemKeyboard)
        if looks != drawnLooks {
            drawnLooks = looks
            keyboardView.stateChanged()
            extraKeysRow.stateChanged()
        }
        let modifiers = ArmedModifiers(control: control.state, alt: alt.state)
        if modifiers != publishedModifiers {
            publishedModifiers = modifiers
            onModifiersChange(modifiers)
        }
    }

    private func preferencesChanged(from old: KeyboardPreferences) {
        extraKeysRow.touches.swipeSpeed = preferences.swipeSpeed
        guard preferences.letters != old.letters else { return }
        resolveLetters()
    }

    /// Follows the first keyboard in the Settings app again, which the user may have changed
    /// since: when the keyboard shows.
    func resolveLetters() {
        let resolved = Self.letters(for: preferences, languages: keyboardLanguages)
        guard resolved != letters else { return }
        letters = resolved
        if layer.kind == .letters {
            layer = .letters(letters)
            keyboardView.layerChanged()
        }
    }

    private static func letters(
        for preferences: KeyboardPreferences, languages: @MainActor () -> [String]
    ) -> LettersLayout {
        (preferences.letters ?? LettersLayout.automatic(forKeyboardLanguages: languages())).layout
    }

    // MARK: - Faces and VoiceOver

    /// How `key` looks, with the keyboard as it is now.
    func face(for key: KeyboardKey, frame: CGRect, isPressed: Bool, metrics: KeyboardMetrics) -> KeyFace {
        let colors = palette
        let label = displayLabel(for: key)
        var face = KeyFace(
            label: label, corner: key.flick,
            labelFont: font(for: key.style, label: label, width: frame.width, metrics: metrics),
            // Corner symbols grow less than labels, which they would otherwise run into.
            cornerFont: typeface.font(size: 9 * min(metrics.labelScale, 1.35), bold: metrics.boldText),
            background: colors.key, foreground: colors.label, cornerColor: colors.secondaryLabel,
            shadow: colors.shadow)
        face.markScale = max(metrics.labelScale, 1)
        switch key.style {
        case .character, .function:
            break
        case .space:
            face.foreground = colors.secondaryLabel
        case .system, .layer:
            face.background = colors.systemKey
            face.foreground = colors.systemLabel
        case .accent:
            face.background = colors.accent
            face.foreground = colors.onAccent
        case .shortcut:
            face.foreground = colors.accentLabel
        case .extra, .extraSymbol:
            face.background = colors.systemKey
            face.shadow = nil
        }
        var isOn = false
        switch key.action {
        case .modifier(let modifier):
            let state = state(of: modifier)
            isOn = state != .off
            if isOn {
                // Shift, and on a light keyboard Control and Alt too, turn dark: the accent alone
                // would hardly stand out from the keys around.
                let isInk = modifier == .shift || !colors.isDark
                face.background = isInk ? colors.activeKey : colors.accent
                face.foreground = isInk ? colors.onActiveKey : colors.onAccent
            }
            face.isLocked = state == .locked
        case .arrows:
            face.label = ""
            face.isRound = true
            face.ring = colors.ring
            face.glyph = .arrows(colors.secondaryLabel, dot: colors.accent)
        case .switchKeyboard:
            face.label = ""
            face.glyph = .symbol(
                usesSystemKeyboard ? "apple.terminal" : "keyboard", weight: metrics.boldText ? .semibold : .regular)
        default:
            break
        }
        if metrics.highContrast {
            // Increase Contrast outlines every key, at more than 3:1 against the keyboard.
            face.ring = colors.secondaryLabel
        }
        if isPressed {
            if key.style == .accent || isOn {
                face.background = face.background.withAlphaComponent(0.75)
            } else {
                // The lighter pressed key takes the full label colour, which keeps 4.5:1.
                face.background = colors.pressedKey
                face.cornerColor = colors.label
                if key.style == .space || key.style == .shortcut {
                    face.foreground = colors.label
                }
            }
        }
        return face
    }

    /// The text a cap shows: letters in capitals while Shift is on, and Shift as Caps Lock when
    /// it is locked.
    func displayLabel(for key: KeyboardKey) -> String {
        switch key.action {
        case .text(let text) where key.style == .character:
            shifted(text)
        case .modifier(.shift):
            shift.state == .locked ? "⇪" : "⇧"
        default:
            key.label
        }
    }

    /// The font of `label` on a key of `style` that is `width` wide: the design's size, scaled
    /// with Dynamic Type, and smaller if the label would not fit.
    private func font(for style: KeyStyle, label: String, width: CGFloat, metrics: KeyboardMetrics) -> UIFont {
        let (size, bold): (CGFloat, Bool) =
            switch style {
            case .character: (17, false)
            case .space: (12, false)
            case .system, .extraSymbol: (16, false)
            case .layer, .accent: (13, false)
            case .function, .shortcut: (11.5, false)
            case .extra: (12.5, true)
            }
        let font = typeface.font(size: size * metrics.labelScale, bold: bold || metrics.boldText)
        let available = width - 6
        let needed = (label as NSString).size(withAttributes: [.font: font]).width
        guard needed > available, available > 0 else { return font }
        return font.withSize(floor(font.pointSize * available / needed))
    }

    /// The font of the callout's items.
    func calloutFont(metrics: KeyboardMetrics) -> UIFont {
        typeface.font(size: 20 * metrics.labelScale, bold: metrics.boldText)
    }

    /// What VoiceOver says for `key`: a letter as it would type, the switch key by the keyboard it
    /// switches to.
    func spokenLabel(for key: KeyboardKey) -> String {
        switch key.action {
        case .text(let text) where key.style == .character && text.first?.isLetter == true:
            shifted(text)
        case .switchKeyboard:
            ExtraKeys.switchKey(toSystemKeyboard: !usesSystemKeyboard).spokenLabel
        default:
            key.spokenLabel
        }
    }

    /// A modifier's state for VoiceOver: Shift is on or Caps Lock, Control and Alt armed or locked.
    func spokenValue(for key: KeyboardKey) -> String? {
        guard case .modifier(let modifier) = key.action else { return nil }
        return Self.spokenState(of: modifier, state(of: modifier))
    }

    private static func spokenState(of modifier: Modifier, _ state: StickyModifier.State) -> String? {
        switch (modifier, state) {
        case (_, .off): nil
        case (.shift, .armed): String(localized: "On")
        case (.shift, .locked): String(localized: "Caps Lock")
        case (_, .armed): String(localized: "Armed")
        case (_, .locked): String(localized: "Locked")
        }
    }

    /// What a key's VoiceOver actions type: its corner symbol, then its alternates, each named
    /// as VoiceOver should say it.
    func accessibilityActions(for key: KeyboardKey) -> [(name: String, text: String)] {
        let items = (key.flick.map { [$0] } ?? []) + key.alternates
        return items.map { item in
            let text = shifted(item)
            return (KeyboardKey.spokenName(of: text), text)
        }
    }

    /// The actions VoiceOver and Switch Control offer on `key`: those that type its corner symbol
    /// and its alternates, and on a modifier, Lock or Unlock, which takes a quick double tap by
    /// touch.
    func accessibilityCustomActions(for key: KeyboardKey) -> [UIAccessibilityCustomAction] {
        var actions = accessibilityActions(for: key).map { action in
            UIAccessibilityCustomAction(name: action.name) { [weak self] _ in
                self?.press(key, text: action.text)
                return true
            }
        }
        if case .modifier(let modifier) = key.action {
            let isLocked = state(of: modifier) == .locked
            let name = isLocked ? String(localized: "Unlock") : String(localized: "Lock")
            actions.append(
                UIAccessibilityCustomAction(name: name) { [weak self] _ in
                    self?.setLocked(modifier, !isLocked)
                    return true
                })
        }
        return actions
    }

    /// The names Voice Control knows `key` by: its spoken name, the label it shows, such as "123"
    /// or "esc", and the other names of some symbols.
    func userInputLabels(for key: KeyboardKey) -> [String] {
        let spoken = spokenLabel(for: key)
        var labels = [spoken]
        let shown = displayLabel(for: key)
        if !shown.isEmpty, shown.caseInsensitiveCompare(spoken) != .orderedSame,
            shown.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        {
            labels.append(shown)
        }
        if case .text(let text) = key.action {
            labels += KeyboardKey.otherNames(of: text)
        }
        if key.action == .switchKeyboard {
            labels.append(String(localized: "Switch Keyboard"))
        }
        if key.action == .arrows {
            labels.append(String(localized: "Arrows"))
        }
        return labels
    }
}

extension TerminalTypeface {
    /// The regular or the bold face at `size`, or the system's monospaced font if the face is not
    /// registered.
    func font(size: CGFloat, bold: Bool) -> UIFont {
        UIFont(name: bold ? self.bold : regular, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
}
