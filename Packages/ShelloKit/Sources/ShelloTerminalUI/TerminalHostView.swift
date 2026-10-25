import ShelloModel
import SwiftTerm
import Synchronization
import UIKit
import os

/// The terminal on screen: SwiftTerm's view (STACK section 7.4) with what Shello adds to it for
/// README section 5. `TerminalController` creates it and is its delegate.
///
/// - Selection: a long-press or a double tap selects a word, a triple tap a line, and handles at
///   either end extend the selection. The menu is a `UIEditMenuInteraction`, which replaces the
///   deprecated `UIMenuController` that SwiftTerm uses: Shello takes over SwiftTerm's own taps and
///   long-press, so SwiftTerm never shows its menu. Copy puts plain text on the pasteboard.
/// - Taps: a program that asked for mouse reports gets a tap as a click; otherwise a tap shows
///   the keyboard, and a tap on the cursor offers Paste.
/// - Paste goes through the controller, which asks before a paste of more lines.
/// - Pinch changes the font size.
/// - Hardware keyboards: SwiftTerm handles Control and Option as Meta; this view adds the key the
///   user chose to send Esc. While one is attached, the Shello keyboard hides.
/// - The Shello keyboard (README section 6) is the input view, and its extra keys row the input
///   accessory view, above the system keyboard too, or alone. Control and Alt, armed on the row,
///   apply to the next key of either keyboard, and of a hardware keyboard.
/// - The cursor stops blinking with Reduce Motion (README section 16), or when the settings say so.
/// - Assistive technologies: activating the terminal shows the keyboard, and its actions read or
///   copy the current line, copy the screen, change the text size without a pinch, and while a
///   hardware keyboard is attached, show or hide the Shello keyboard.
public final class TerminalHostView: TerminalView, UIEditMenuInteractionDelegate {
    /// Receives what this view leaves to its controller.
    weak var events: (any TerminalHostViewEvents)?

    private(set) var preferences: TerminalPreferences
    public let theme: TerminalTheme
    private let typeface: TerminalTypeface
    private let renderer: TerminalRenderer
    /// The Shello keyboard and the extra keys row of this terminal.
    let keyboard: ShelloKeyboard

    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var isShowingEditMenu = false
    /// The selection this view made, which its handles move. Nil when there is none, or when
    /// SwiftTerm selected something itself, as a search does.
    private var selectionRange: (start: Position, end: Position)?
    /// While a handle is dragged: the other end of the selection, which stays put.
    private var dragAnchor: Position?
    private let handleDrag = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private var fontSizeAtPinchStart: CGFloat?
    private var bellFlash: UIView?
    /// Whether the cursor stays steady, read by SwiftTerm's thread when a program changes the cursor.
    private nonisolated let keepsCursorSteady = Mutex(false)
    /// Whether the alternate screen shows, as a full-screen program such as vim switches to it,
    /// written by SwiftTerm's thread as it does.
    private nonisolated let showsAlternateScreen = Mutex(false)
    /// Follows whether a hardware keyboard is attached, which hides the Shello keyboard.
    private var hardwareKeyboardObservation: HardwareKeyboardObservation?

    init(
        preferences: TerminalPreferences, theme: TerminalTheme, typeface: TerminalTypeface, renderer: TerminalRenderer,
        hardwareKeyboard: (any HardwareKeyboardMonitor)? = nil
    ) {
        self.preferences = preferences
        self.theme = theme
        self.typeface = typeface
        self.renderer = renderer
        let keyboard = ShelloKeyboard(theme: theme, typeface: typeface, preferences: preferences.keyboard)
        keyboard.hardwareKeyboardChanged(isAttached: hardwareKeyboard?.isAttached ?? false)
        self.keyboard = keyboard
        var options = TerminalOptions.default
        options.scrollback = preferences.scrollbackLines
        // xterm's fixed 6×6×6 cube and grey ramp, which programs expect for colours 16 to 255.
        options.ansi256PaletteStrategy = .xterm
        // A flag is two regional indicators of one column each, as wcwidth() and tmux count them.
        options.regionalIndicatorWidth = .narrow
        super.init(frame: .zero, font: nil, options: options)
        configure()
        hardwareKeyboardObservation = hardwareKeyboard?.observe { [weak self] isAttached in
            self?.keyboard.hardwareKeyboardChanged(isAttached: isAttached)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure() {
        // The Shello keyboard and its extra keys row, in place of SwiftTerm's own row, whose keys
        // have no VoiceOver labels.
        keyboard.terminal = self
        keyboard.onModifiersChange = { [weak self] modifiers in
            guard let self else { return }
            self.events?.terminalView(self, modifiersChanged: modifiers)
        }
        inputView = keyboard.inputView
        inputAccessoryView = keyboard.accessoryView
        contentInsetAdjustmentBehavior = .never
        // The theme is dark whatever the app's appearance, and so are the keyboard, the edit menu
        // and the scroll indicator over it.
        overrideUserInterfaceStyle = .dark
        keyboardAppearance = .dark
        indicatorStyle = .white
        backgroundColor = theme.background.uiColor
        layer.backgroundColor = theme.background.uiColor.cgColor
        nativeForegroundColor = theme.foreground.uiColor
        nativeBackgroundColor = theme.background.uiColor
        installColors(theme.ansi.map(\.terminalColor))
        caretColor = theme.accent.uiColor
        caretTextColor = theme.onAccent.uiColor
        selectedTextBackgroundColor = theme.accent.uiColor
        selectedTextForegroundColor = theme.onAccent.uiColor
        selectionHandleColor = theme.accent.uiColor
        // The delegate's bell gives the haptic tap and the flash.
        bellStyle = .sound
        optionAsMetaKey = preferences.optionAsMeta
        applyFont(size: preferences.fontSize)

        takeOverGestures()
        addInteraction(editMenu)
        pinch.addTarget(self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
        handleDrag.addTarget(self, action: #selector(handleDragged(_:)))
        handleDrag.maximumNumberOfTouches = 1
        addGestureRecognizer(handleDrag)
        // Scrolling waits for the handle drag, which fails at once away from a handle.
        panGestureRecognizer.require(toFail: handleDrag)

        accessibilityLabel = "Terminal"
        accessibilityIdentifier = "terminal"
        // Smart Invert would turn the dark terminal light, and its colours into others.
        accessibilityIgnoresInvertColors = true
        updateAccessibilityActions()

        updateCursorBlink()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // SwiftTerm sets up Metal once the view is in a window.
        guard renderer == .metal, window != nil, !isUsingMetalRenderer else { return }
        do {
            try setUseMetal(true)
        } catch {
            Self.logger.error("Metal is not available, the terminal draws with CoreText: \(error)")
        }
    }

    // MARK: - Preferences

    /// Applies changed settings. A new font size resizes the grid, which reports the new size.
    func apply(_ newPreferences: TerminalPreferences) {
        let old = preferences
        preferences = newPreferences
        if newPreferences.fontSize != old.fontSize {
            applyFont(size: newPreferences.fontSize)
        }
        if newPreferences.scrollbackLines != old.scrollbackLines {
            changeScrollback(newPreferences.scrollbackLines)
        }
        optionAsMetaKey = newPreferences.optionAsMeta
        keyboard.preferences = newPreferences.keyboard
        if newPreferences.cursorBlinks != old.cursorBlinks {
            updateCursorBlink()
        }
    }

    private func applyFont(size: CGFloat) {
        let fonts = typeface.fonts(size: size)
        setFonts(normal: fonts.regular, bold: fonts.bold, italic: fonts.italic, boldItalic: fonts.boldItalic)
        // A new font clears the selection.
        selectionRange = nil
    }

    // MARK: - Geometry

    /// The size of one character cell, in points.
    var cellSize: CGSize {
        let dimensions = terminalDimensions
        let frame = getOptimalFrameSize()
        guard dimensions.cols > 0, dimensions.rows > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: frame.width / CGFloat(dimensions.cols), height: frame.height / CGFloat(dimensions.rows))
    }

    /// The terminal's size, for the remote end.
    var currentSize: TerminalSize {
        let dimensions = terminalDimensions
        let frame = getOptimalFrameSize()
        let scale = max(traitCollection.displayScale, 1)
        return TerminalSize(
            columns: dimensions.cols, rows: dimensions.rows, pixelWidth: Int(frame.width * scale),
            pixelHeight: Int(frame.height * scale))
    }

    /// The cell under `point`, in the buffer's coordinates, scrollback included: the view scrolls
    /// over the whole buffer, a row of cells per line.
    private func position(at point: CGPoint) -> Position {
        let cell = cellSize
        let columns = terminalDimensions.cols
        return Position(
            col: min(max(Int(point.x / cell.width), 0), max(columns - 1, 0)),
            row: max(Int(point.y / cell.height), 0))
    }

    // MARK: - Taps and selection

    /// Gives SwiftTerm's tap and long-press recognizers Shello's actions, keeping their order:
    /// a single tap still waits for a double tap to fail, and a double tap for a triple tap.
    /// The scroll view's own recognizers have a delegate; SwiftTerm's do not.
    private func takeOverGestures() {
        for recognizer in gestureRecognizers ?? [] where recognizer.delegate == nil {
            // Exactly these classes: the scroll view's private recognizers subclass them.
            if type(of: recognizer) == UILongPressGestureRecognizer.self,
                let press = recognizer as? UILongPressGestureRecognizer
            {
                press.removeTarget(nil, action: nil)
                press.addTarget(self, action: #selector(longPressed(_:)))
                // The system's duration, rather than SwiftTerm's 0.7 seconds.
                press.minimumPressDuration = 0.5
            } else if type(of: recognizer) == UITapGestureRecognizer.self,
                let tap = recognizer as? UITapGestureRecognizer
            {
                tap.removeTarget(nil, action: nil)
                switch tap.numberOfTapsRequired {
                case 1: tap.addTarget(self, action: #selector(tapped(_:)))
                case 2: tap.addTarget(self, action: #selector(doubleTapped(_:)))
                default: tap.addTarget(self, action: #selector(tripleTapped(_:)))
                }
            }
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        if hasActiveSelection || isShowingEditMenu {
            clearSelectionAndMenu()
            return
        }
        // A program that asked for mouse reports gets the tap as a click, focused or not.
        if forwardTap(at: point) {
            return
        }
        guard isFirstResponder else {
            _ = becomeFirstResponder()
            return
        }
        // A tap on the cursor offers Paste, as in a text field.
        let cell = cellSize
        if caretFrame.insetBy(dx: -cell.width, dy: -cell.height / 2).contains(point) {
            showEditMenu(at: point)
        }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        if selectWord(at: point) {
            showEditMenu(at: point)
        }
    }

    @objc private func tripleTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        let row = position(at: point).row
        select(from: Position(col: 0, row: row), to: Position(col: max(terminalDimensions.cols - 1, 0), row: row))
        showEditMenu(at: point)
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: self)
        if !selectWord(at: point) {
            clearSelection()
            selectionRange = nil
        }
        showEditMenu(at: point)
    }

    /// Selects the word under `point`, and returns whether there is one.
    @discardableResult
    func selectWord(at point: CGPoint) -> Bool {
        let position = position(at: point)
        let snapshot = terminalStateSnapshot()
        let visibleRow = position.row - snapshot.viewportRow
        guard let row = snapshot.visibleRows.first(where: { $0.row == visibleRow }),
            let columns = TerminalWord.columns(
                at: position.col, in: TerminalWord.cells(text: row.text, widths: row.cellWidths))
        else { return false }
        select(
            from: Position(col: columns.lowerBound, row: position.row),
            to: Position(col: columns.upperBound, row: position.row))
        return true
    }

    /// Selects from `start` to `end`, the end exclusive, as SwiftTerm counts it.
    private func select(from start: Position, to end: Position) {
        setSelectionRange(start: start, end: end)
        selectionRange = (start, end)
    }

    private func clearSelectionAndMenu() {
        clearSelection()
        selectionRange = nil
        editMenu.dismissMenu()
    }

    /// Where the selection is, for the menu to keep clear of.
    private var selectionRect: CGRect? {
        guard hasActiveSelection, let (start, end) = selectionRange else { return nil }
        let cell = cellSize
        let isOneLine = start.row == end.row
        return CGRect(
            x: isOneLine ? CGFloat(start.col) * cell.width : 0, y: CGFloat(start.row) * cell.height,
            width: isOneLine ? CGFloat(max(end.col - start.col, 1)) * cell.width : bounds.width,
            height: CGFloat(end.row - start.row + 1) * cell.height)
    }

    // MARK: - Selection handles

    public override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === handleDrag {
            return anchorForHandle(at: recognizer.location(in: self)) != nil
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    /// The end of the selection that stays put while the handle at `point` is dragged, or nil
    /// when `point` is not on a handle. SwiftTerm draws the start's handle at the top of the first
    /// cell, and the end's at the bottom of the cell after the last.
    private func anchorForHandle(at point: CGPoint) -> Position? {
        guard hasActiveSelection, let (start, end) = selectionRange else { return nil }
        let cell = cellSize
        let startHandle = CGPoint(x: CGFloat(start.col) * cell.width, y: CGFloat(start.row) * cell.height)
        let endHandle = CGPoint(x: CGFloat(end.col) * cell.width, y: CGFloat(end.row + 1) * cell.height)
        // A finger's reach, the size of a minimum touch target.
        let reach: CGFloat = 22
        if hypot(point.x - endHandle.x, point.y - endHandle.y) <= reach {
            return start
        }
        if hypot(point.x - startHandle.x, point.y - startHandle.y) <= reach {
            return end
        }
        return nil
    }

    @objc private func handleDragged(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            dragAnchor = anchorForHandle(at: point)
            editMenu.dismissMenu()
        case .changed:
            guard let anchor = dragAnchor else { return }
            var moved = position(at: point)
            // The end is exclusive: a handle dragged forward covers the cell it is over.
            if Position.compare(moved, anchor) != .before {
                moved.col += 1
            }
            if Position.compare(moved, anchor) == .before {
                select(from: moved, to: anchor)
            } else {
                select(from: anchor, to: moved)
            }
        case .ended:
            dragAnchor = nil
            showEditMenu(at: point)
        default:
            dragAnchor = nil
        }
    }

    // MARK: - Edit menu

    func showEditMenu(at point: CGPoint) {
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        UIMenu(children: Self.editActions(suggestedActions, canPaste: UIPasteboard.general.hasStrings))
    }

    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        selectionRect ?? CGRect(origin: configuration.sourcePoint, size: cellSize)
    }

    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        isShowingEditMenu = true
    }

    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        isShowingEditMenu = false
    }

    /// The system's edit actions for the terminal, without Select: SwiftTerm's Select picks the
    /// word under its own long-press menu, which this view never shows. Paste only shows when the
    /// pasteboard holds text.
    static func editActions(_ elements: [UIMenuElement], canPaste: Bool) -> [UIMenuElement] {
        elements.compactMap { element in
            if let menu = element as? UIMenu {
                return menu.replacingChildren(editActions(menu.children, canPaste: canPaste))
            }
            if let command = element as? UICommand {
                switch command.action {
                case #selector(UIResponderStandardEditActions.select(_:)): return nil
                case #selector(UIResponderStandardEditActions.paste(_:)) where !canPaste: return nil
                default: return command
                }
            }
            return element
        }
    }

    public override func copy(_ sender: Any?) {
        // SwiftTerm copies the selection as plain text and clears it.
        super.copy(sender)
        selectionRange = nil
    }

    public override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        events?.terminalView(self, wantsToPaste: text)
    }

    public override func selectAll(_ sender: Any?) {
        selectAll()
        selectionRange = nil
        if let point = editMenuSourcePoint {
            showEditMenu(at: point)
        }
    }

    /// Where Select All's menu shows again: over the terminal's top left, where the selection
    /// starts on screen.
    private var editMenuSourcePoint: CGPoint? {
        CGPoint(x: bounds.minX + cellSize.width, y: bounds.minY + cellSize.height)
    }

    // MARK: - Pinch

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            fontSizeAtPinchStart = preferences.fontSize
        case .changed:
            guard let start = fontSizeAtPinchStart else { return }
            let size = TerminalPreferences.clampedFontSize(start * recognizer.scale)
            if size != preferences.fontSize {
                events?.terminalView(self, zoomedTo: size)
            }
        default:
            fontSizeAtPinchStart = nil
        }
    }

    // MARK: - Hardware keyboard

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var others = presses
        for press in presses {
            guard let key = press.key,
                preferences.escapeKey.sendsEscape(keyCode: key.keyCode, modifiers: key.modifierFlags)
            else { continue }
            send([0x1B])
            others.remove(press)
        }
        if !others.isEmpty {
            super.pressesBegan(others, with: event)
        }
    }

    // MARK: - Keyboards

    /// Text from the system keyboard, or a hardware keyboard's letters: Control or Alt armed on the
    /// extra keys row applies to it (README section 6).
    public override func insertText(_ text: String) {
        if keyboard.typeFromSystemKeyboard(text) {
            return
        }
        super.insertText(text)
    }

    public override func deleteBackward() {
        if keyboard.deleteBackwardFromSystemKeyboard() {
            return
        }
        super.deleteBackward()
    }

    /// Shows what the Shello keyboard says the terminal types with, after its switch key, a hardware
    /// keyboard or the settings changed it (README section 6). The terminal keeps the keyboard focus:
    /// its input views reload, and it does not resign. Only the terminal with the keyboard focus tells
    /// VoiceOver, whose focus never stays on keys that went away, and which hears what changed where
    /// its focus does not say it: the other terminals' keys are not on screen.
    func keyboardChanged(_ change: KeysChange) {
        let focused = keyboard.feedback.voiceOverFocus()
        inputView = keyboard.inputView
        inputAccessoryView = keyboard.accessoryView
        updateAccessibilityActions()
        guard isFirstResponder else { return }
        reloadInputViews()
        guard hasKeyboardFocus else { return }
        let focus = keyboard.voiceOverFocus(after: change, from: focused, terminal: self)
        keyboard.feedback.layoutChanged(focus)
        let wentToTheSwitchKey = focus === keyboard.extraKeysRow.switchAccessibilityElement
        if keyboard.feedback.isVoiceOverRunning(),
            let announcement = keyboard.announcement(for: change, focusWentToTheSwitchKey: wentToTheSwitchKey)
        {
            keyboard.feedback.announce(announcement)
        }
    }

    /// Whether the terminal has the keyboard focus that VoiceOver follows: it is the first responder
    /// of the key window, in a scene in front. On iPad, each window has a first responder of its own.
    private var hasKeyboardFocus: Bool {
        guard isFirstResponder, let window, window.isKeyWindow else { return false }
        return window.windowScene.map { $0.activationState == .foregroundActive } ?? true
    }

    /// The terminal's actions for assistive technologies, and while a hardware keyboard is attached,
    /// the switch key's: Show Shello Keyboard or Hide Shello Keyboard. Without the extra keys row, it
    /// is the one way to the Shello keyboard for VoiceOver, Switch Control and Full Keyboard Access.
    private func updateAccessibilityActions() {
        var actions = TerminalAccessibilityAction.allCases.map { action in
            UIAccessibilityCustomAction(name: action.name) { [weak self] _ in
                guard let self, let events = self.events else { return false }
                events.terminalView(self, performs: action)
                return true
            }
        }
        if keyboard.isHardwareKeyboardAttached {
            actions.append(
                UIAccessibilityCustomAction(name: keyboard.switchKey.spokenLabel) { [weak self] _ in
                    guard let self else { return false }
                    if !self.isFirstResponder {
                        _ = self.becomeFirstResponder()
                    }
                    self.keyboard.switchKeyboard()
                    return true
                })
        }
        accessibilityCustomActions = actions
    }

    // MARK: - Bell

    /// Flashes the terminal briefly in its text colour: the bell's visual half (README section 5).
    func flashForBell() {
        bellFlash?.removeFromSuperview()
        let flash = UIView(frame: bounds)
        flash.backgroundColor = theme.foreground.uiColor
        flash.alpha = 0
        flash.isUserInteractionEnabled = false
        addSubview(flash)
        bellFlash = flash
        UIView.animateKeyframes(withDuration: 0.25, delay: 0) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) { flash.alpha = 0.3 }
            UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.7) { flash.alpha = 0 }
        } completion: { [weak self] _ in
            MainActor.assumeIsolated {
                flash.removeFromSuperview()
                if self?.bellFlash === flash {
                    self?.bellFlash = nil
                }
            }
        }
    }

    /// Whether the bell's flash is showing.
    var isFlashingForBell: Bool { bellFlash != nil }

    // MARK: - Reduce Motion

    @objc private func reduceMotionChanged() {
        updateCursorBlink()
    }

    /// The cursor blinks unless Reduce Motion is on or the settings say it does not.
    private func updateCursorBlink() {
        let steady = UIAccessibility.isReduceMotionEnabled || !preferences.cursorBlinks
        keepsCursorSteady.withLock { $0 = steady }
        setCursorStyle(steady ? .steadyBlock : .blinkBlock)
    }

    /// Whether the cursor stays steady, whatever a program asks for.
    var isCursorSteady: Bool { keepsCursorSteady.withLock { $0 } }

    /// A program can ask for a blinking cursor (DECSCUSR); with Reduce Motion, or when the settings
    /// say so, it stays steady.
    public nonisolated override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        let style = keepsCursorSteady.withLock { $0 } ? newStyle.steady : newStyle
        super.cursorStyleChanged(source: source, newStyle: style)
    }

    // MARK: - The alternate screen

    /// A program switched between the normal screen and the alternate one.
    public nonisolated override func bufferActivated(source: Terminal) {
        let isAlternate = source.isCurrentBufferAlternate
        showsAlternateScreen.withLock { $0 = isAlternate }
        super.bufferActivated(source: source)
    }

    /// Whether the alternate screen shows: a full-screen program, such as vim or less, is on it.
    var isShowingAlternateScreen: Bool { showsAlternateScreen.withLock { $0 } }

    // MARK: - Assistive technologies

    /// VoiceOver's double tap, Voice Control's tap and Full Keyboard Access's activation show the
    /// keyboard. A tap in the middle of the terminal, the default, and the fallback when this
    /// returns false, could be a click that a program in mouse mode receives.
    public override func accessibilityActivate() -> Bool {
        _ = becomeFirstResponder()
        return true
    }

    /// VoiceOver's escape gesture puts the keyboard away; without the keyboard, it goes back.
    public override func accessibilityPerformEscape() -> Bool {
        guard isFirstResponder else { return false }
        return resignFirstResponder()
    }

    /// The text on screen, a line of text per line of output: a line too long for the screen
    /// continues on the rows after it.
    var screenText: String {
        var lines: [String] = []
        for row in terminalStateSnapshot().visibleRows {
            if row.isWrapped, let line = lines.popLast() {
                lines.append(line + row.text)
            } else {
                lines.append(row.text)
            }
        }
        let trimmed = lines.map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
        return trimmed.reversed().drop(while: \.isEmpty).reversed().joined(separator: "\n")
    }

    /// The text of the line the cursor is on, for VoiceOver.
    var currentLine: String {
        let snapshot = terminalStateSnapshot()
        let lines = String(decoding: getBufferAsData(), as: UTF8.self).split(
            separator: "\n", omittingEmptySubsequences: false)
        // The buffer ends with the screen; the cursor's row counts from the screen's top.
        let index = lines.count - 1 - snapshot.dimensions.rows + snapshot.cursor.row
        guard lines.indices.contains(index) else { return "" }
        return String(lines[index]).trimmingCharacters(in: .whitespaces)
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Terminal")
}

/// What the terminal view leaves to its controller.
protocol TerminalHostViewEvents: AnyObject {
    /// The user pasted `text`, which the controller sends or asks about first.
    func terminalView(_ view: TerminalHostView, wantsToPaste text: String)
    /// A pinch reached the font size `fontSize`.
    func terminalView(_ view: TerminalHostView, zoomedTo fontSize: CGFloat)
    /// The user chose one of the terminal's actions for assistive technologies.
    func terminalView(_ view: TerminalHostView, performs action: TerminalAccessibilityAction)
    /// Control or Alt, on the extra keys row, changed.
    func terminalView(_ view: TerminalHostView, modifiersChanged modifiers: ArmedModifiers)
}

/// The terminal's actions for VoiceOver, Voice Control and Switch Control: what the user would
/// otherwise do by looking at the screen, or with a gesture of two fingers.
enum TerminalAccessibilityAction: CaseIterable {
    case readCurrentLine
    case copyCurrentLine
    case copyScreen
    case biggerText
    case smallerText

    var name: String {
        switch self {
        case .readCurrentLine: "Read Current Line"
        case .copyCurrentLine: "Copy Current Line"
        case .copyScreen: "Copy Screen"
        case .biggerText: "Bigger Text"
        case .smallerText: "Smaller Text"
        }
    }
}

/// How a terminal draws, chosen by measurement (STACK section 6, spike item 8).
nonisolated public enum TerminalRenderer: Sendable {
    /// SwiftTerm's CoreGraphics and CoreText drawing, on the main thread.
    case coreText
    /// SwiftTerm's Metal renderer, with a glyph atlas on the GPU.
    case metal
}

nonisolated extension CursorStyle {
    /// The same shape, without the blink.
    fileprivate var steady: CursorStyle {
        switch self {
        case .blinkBlock, .steadyBlock: .steadyBlock
        case .blinkUnderline, .steadyUnderline: .steadyUnderline
        case .blinkBar, .steadyBar: .steadyBar
        }
    }
}
