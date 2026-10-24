import QuartzCore
import UIKit

/// The Shello keyboard (GLOSSARY, README section 6): the terminal's input view, in place of the
/// system keyboard. Its keys are Core Animation layers, and one gesture recognizer takes every
/// touch (STACK section 7.5). For VoiceOver each key is an element of its own, a keyboard key
/// whose activation presses it, so VoiceOver's typing modes work as with the system keyboard.
final class ShelloKeyboardView: UIInputView, UIInputViewAudioFeedback {
    private weak var keyboard: ShelloKeyboard?
    let touches = KeyTouches()
    private let recognizer: KeyboardGestureRecognizer
    private(set) var metrics = KeyboardMetrics(
        keyHeight: 44, keySpacing: 5, rowSpacing: 10, insets: .zero, cornerRadius: 7, labelScale: 1)
    private(set) var geometry = KeyboardGeometry(
        rows: [], width: 0,
        metrics: .init(
            keyHeight: 44, keySpacing: 5, rowSpacing: 10, insets: .zero, cornerRadius: 7, labelScale: 1))
    private var caps: [KeyCap] = []
    /// The keys drawn pressed, and whether every key needs drawing again: otherwise a touch only
    /// draws the keys it presses and lets go.
    private var drawnPressed: Set<Int> = []
    private var needsFullRender = true
    private let callout = KeyCalloutView()
    private var elements: [KeyAccessibilityElement] = []
    private var tick: Timer?

    init(keyboard: ShelloKeyboard) {
        self.keyboard = keyboard
        recognizer = KeyboardGestureRecognizer(touches: touches)
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 260), inputViewStyle: .default)
        allowsSelfSizing = true
        isMultipleTouchEnabled = true
        backgroundColor = keyboard.palette.background
        overrideUserInterfaceStyle = keyboard.palette.isDark ? .dark : .light
        accessibilityIdentifier = "Shello Keyboard"
        layer.addSublayer(callout.layer)

        touches.hitTest = { [weak self] point in self?.geometry.hit(at: point) }
        touches.onEvent = { [weak self] event in self?.keyboard?.handle(event) }
        recognizer.onChange = { [weak self] in self?.touchesChanged() }
        addGestureRecognizer(recognizer)

        registerForTraitChanges(
            [
                UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self,
                UITraitVerticalSizeClass.self, UITraitDisplayScale.self, UITraitLegibilityWeight.self,
                UITraitAccessibilityContrast.self,
            ]
        ) { (view: ShelloKeyboardView, _) in
            view.metricsChanged()
        }
        metricsChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Input clicks, which the keys play through `UIDevice.playInputClick()` (STACK section 7.5).
    var enableInputClicksWhenVisible: Bool { true }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: Self.height(rows: keyboard?.layer.rows.count ?? 4, metrics: metrics))
    }

    private static func height(rows: Int, metrics: KeyboardMetrics) -> CGFloat {
        let count = CGFloat(rows)
        return metrics.insets.top + metrics.insets.bottom + count * metrics.keyHeight
            + max(count - 1, 0) * metrics.rowSpacing
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The first keyboard in the Settings app may have changed while Shello was away.
        if window != nil {
            keyboard?.resolveLetters()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutKeys()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    // MARK: - Keys

    /// A new layer: its keys replace the others. VoiceOver moves to the key now where the key that
    /// chose the layer was, which the layers share, and says it, such as "Letters".
    func layerChanged() {
        let chooser = keyboard.flatMap { keyboard in
            geometry.caps.first { $0.key.action == .layer(keyboard.layer.kind) }
        }
        touches.cancelAll()
        layoutKeys()
        invalidateIntrinsicContentSize()
        let focus = chooser.flatMap { chooser in
            geometry.caps.firstIndex { $0.touchFrame.contains(CGPoint(x: chooser.frame.midX, y: chooser.frame.midY)) }
        }
        UIAccessibility.post(notification: .layoutChanged, argument: focus.map { elements[$0] })
    }

    /// Shift, a modifier or the keyboard changed: the keys show it.
    func stateChanged() {
        needsFullRender = true
        render()
        updateAccessibility()
    }

    private func metricsChanged() {
        metrics = .keyboard(for: traitCollection)
        invalidateIntrinsicContentSize()
        layoutKeys()
    }

    /// Lays the layer's keys out across the view, clear of the safe area at the sides, as in
    /// landscape on a phone with a notch.
    private func layoutKeys() {
        guard let keyboard else { return }
        var inset = metrics
        inset.insets.left += safeAreaInsets.left
        inset.insets.right += safeAreaInsets.right
        let newGeometry = KeyboardGeometry(rows: keyboard.layer.rows, width: bounds.width, metrics: inset)
        touches.bounds = bounds
        needsFullRender = true
        guard newGeometry != geometry || caps.count != newGeometry.caps.count else {
            render()
            return
        }
        geometry = newGeometry
        while caps.count < geometry.caps.count {
            let cap = KeyCap()
            layer.insertSublayer(cap.layer, below: callout.layer)
            caps.append(cap)
        }
        for (index, cap) in caps.enumerated() {
            cap.layer.isHidden = index >= geometry.caps.count
        }
        render()
        rebuildAccessibility()
    }

    private func render() {
        guard let keyboard else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pressed = touches.pressedIndexes
        let changed = needsFullRender ? Set(geometry.caps.indices) : pressed.symmetricDifference(drawnPressed)
        needsFullRender = false
        drawnPressed = pressed
        let scale = traitCollection.displayScale
        for index in changed where geometry.caps.indices.contains(index) {
            let cap = geometry.caps[index]
            let face = keyboard.face(
                for: cap.key, frame: cap.frame, isPressed: pressed.contains(index), metrics: metrics)
            caps[index].draw(face, frame: cap.frame, cornerRadius: metrics.cornerRadius, scale: scale)
        }
        callout.draw(
            touches.callout, text: keyboard.shifted, font: keyboard.calloutFont(metrics: metrics),
            palette: keyboard.palette, scale: scale)
        CATransaction.commit()
    }

    private func touchesChanged() {
        render()
        scheduleTick()
    }

    /// Wakes the touches when their next long-press, repeat or arrow is due.
    private func scheduleTick() {
        tick?.invalidate()
        tick = nil
        guard let deadline = touches.deadline else { return }
        let timer = Timer(timeInterval: max(deadline - CACurrentMediaTime(), 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.touches.tick(at: CACurrentMediaTime())
                self.touchesChanged()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    // MARK: - Accessibility

    /// One element per key, kept across layers, rotation and text sizes, so that the one
    /// VoiceOver is on stays: each takes the key now at its place.
    private func rebuildAccessibility() {
        while elements.count < geometry.caps.count {
            let index = elements.count
            let element = KeyAccessibilityElement(accessibilityContainer: self)
            element.press = { [weak self] in
                guard let self, let keyboard = self.keyboard, self.geometry.caps.indices.contains(index) else { return }
                keyboard.press(self.geometry.caps[index].key)
            }
            elements.append(element)
        }
        for (element, cap) in zip(elements, geometry.caps) {
            element.accessibilityFrameInContainerSpace = cap.touchFrame
        }
        accessibilityElements = Array(elements.prefix(geometry.caps.count))
        updateAccessibility()
    }

    /// The keys' names, states and actions, as they change with the layer, Shift and the
    /// modifiers.
    private func updateAccessibility() {
        guard let keyboard else { return }
        for (element, cap) in zip(elements, geometry.caps) {
            element.accessibilityLabel = keyboard.spokenLabel(for: cap.key)
            element.accessibilityValue = keyboard.spokenValue(for: cap.key)
            element.accessibilityTraits = .keyboardKey
            element.accessibilityUserInputLabels = keyboard.userInputLabels(for: cap.key)
            element.accessibilityCustomActions = keyboard.accessibilityCustomActions(for: cap.key)
        }
    }
}
