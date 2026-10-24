import QuartzCore
import UIKit

/// The extra keys row (GLOSSARY, README section 6): the terminal's input accessory view, above
/// whichever keyboard is up. Its keys scroll sideways in a `UIScrollView` (STACK section 7.5) and
/// fade out under its end, where the key that switches between the Shello keyboard and the system
/// keyboard stays put: the one key that can bring the Shello keyboard back.
///
/// Like the keyboard, its keys are Core Animation layers with one gesture recognizer. A tap types
/// as the finger lifts, unless the finger dragged the row sideways; the swipe key takes its drags.
final class ExtraKeysRow: UIInputView, UIInputViewAudioFeedback, UIScrollViewDelegate {
    private weak var keyboard: ShelloKeyboard?
    let keys: [KeyboardKey]
    let touches = KeyTouches()
    private let recognizer: KeyboardGestureRecognizer
    private let scrollView = ExtraKeysScrollView()
    /// Clips and fades the scrolling keys; the scroll view inside it scrolls them.
    private let scrollArea = UIView()
    private let fade = CAGradientLayer()
    private let keysView = UIView()
    private let switchKeyView = UIView()
    private(set) var metrics = KeyboardMetrics(
        keyHeight: 42, keySpacing: 6, rowSpacing: 0, insets: .zero, cornerRadius: 9, labelScale: 1)
    private(set) var geometry = KeyboardGeometry(
        row: [],
        metrics: .init(
            keyHeight: 42, keySpacing: 6, rowSpacing: 0, insets: .zero, cornerRadius: 9, labelScale: 1))
    private var caps: [KeyCap] = []
    private let switchCap = KeyCap()
    /// The keys drawn pressed, and whether every key needs drawing again, as on the keyboard.
    private var drawnPressed: Set<Int> = []
    private var needsFullRender = true
    private var elements: [KeyAccessibilityElement] = []
    private let switchElement: KeyAccessibilityElement
    private var tick: Timer?

    init(keyboard: ShelloKeyboard, keys: [KeyboardKey] = ExtraKeys.standard) {
        self.keyboard = keyboard
        self.keys = keys
        recognizer = KeyboardGestureRecognizer(touches: touches)
        switchElement = KeyAccessibilityElement(accessibilityContainer: switchKeyView)
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 50), inputViewStyle: .default)
        allowsSelfSizing = true
        isMultipleTouchEnabled = true
        backgroundColor = keyboard.palette.background
        overrideUserInterfaceStyle = keyboard.palette.isDark ? .dark : .light
        accessibilityIdentifier = "Extra Keys"

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        // A key acts at once, not after the scroll view has waited to see whether a drag follows.
        scrollView.delaysContentTouches = false
        scrollView.delegate = self
        scrollView.startsDrag = { [weak self] point in
            guard let self, let hit = self.hit(at: point) else { return true }
            return hit.key.action != .arrows
        }
        scrollView.addSubview(keysView)
        scrollArea.addSubview(scrollView)
        scrollArea.layer.mask = fade
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        addSubview(scrollArea)
        switchKeyView.layer.addSublayer(switchCap.layer)
        addSubview(switchKeyView)

        touches.swipeSpeed = keyboard.preferences.swipeSpeed
        touches.tapsSendArrows = { [weak keyboard] in !(keyboard?.feedback.isVoiceOverRunning() ?? false) }
        touches.hitTest = { [weak self] point in self?.hit(at: point) }
        touches.onEvent = { [weak self] event in self?.keyboard?.handle(event) }
        recognizer.claimsTouchesAtOnce = false
        recognizer.ignoresTouch = { [weak self] _ in
            // A tap that stops the row gliding only stops it.
            self?.scrollView.isDecelerating ?? false
        }
        recognizer.onChange = { [weak self] in self?.touchesChanged() }
        addGestureRecognizer(recognizer)

        registerForTraitChanges(
            [
                UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self,
                UITraitVerticalSizeClass.self, UITraitDisplayScale.self, UITraitLegibilityWeight.self,
                UITraitAccessibilityContrast.self,
            ]
        ) { (view: ExtraKeysRow, _) in
            view.metricsChanged()
        }
        makeAccessibilityElements()
        metricsChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var enableInputClicksWhenVisible: Bool { true }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: metrics.insets.top + metrics.keyHeight + metrics.insets.bottom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutKeys()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// Shift, a modifier or the keyboard changed: the keys show it.
    func stateChanged() {
        needsFullRender = true
        render()
        updateAccessibility()
    }

    private func metricsChanged() {
        metrics = .extraKeysRow(for: traitCollection)
        geometry = KeyboardGeometry(row: keys, metrics: metrics)
        invalidateIntrinsicContentSize()
        while caps.count < geometry.caps.count {
            let cap = KeyCap()
            keysView.layer.addSublayer(cap.layer)
            caps.append(cap)
        }
        updateAccessibility()
        setNeedsLayout()
    }

    /// The row's frames: the scrolling keys from the leading edge, clear of the safe area, and the
    /// switch key at the trailing edge, with the fade between them.
    private var switchKeyFrame: CGRect {
        let width = metrics.keyHeight
        return CGRect(
            x: bounds.width - safeAreaInsets.right - metrics.insets.right - width, y: metrics.insets.top, width: width,
            height: metrics.keyHeight)
    }

    private func layoutKeys() {
        let switchFrame = switchKeyFrame
        let areaWidth = max(switchFrame.minX - metrics.keySpacing / 2 - safeAreaInsets.left, 0)
        scrollArea.frame = CGRect(x: safeAreaInsets.left, y: 0, width: areaWidth, height: bounds.height)
        scrollView.frame = scrollArea.bounds
        keysView.frame = CGRect(origin: .zero, size: geometry.size)
        scrollView.contentSize = geometry.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scrollArea.bounds
        CATransaction.commit()
        updateFade()
        switchKeyView.frame = switchFrame
        touches.bounds = bounds
        needsFullRender = true
        render()
        updateAccessibility()
    }

    /// Fades the keys out under the end of the row while more of them lie beyond it.
    private func updateFade() {
        let width = max(scrollArea.bounds.width, 1)
        let hasMore = scrollView.contentOffset.x + width < geometry.size.width - 1
        let fadeWidth = hasMore ? min(metrics.keyHeight, width / 4) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.locations = [0, NSNumber(value: Double((width - fadeWidth) / width)), 1]
        fade.colors = [
            UIColor.black.cgColor, UIColor.black.cgColor, (hasMore ? UIColor.clear : UIColor.black).cgColor,
        ]
        CATransaction.commit()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFade()
    }

    /// The key under `point`, in the row's coordinates: a scrolling key, at its place on screen,
    /// or the switch key, which comes after them.
    private func hit(at point: CGPoint) -> KeyTouches.Hit? {
        let switchFrame = switchKeyFrame
        let switchTouchFrame = CGRect(
            x: switchFrame.minX - metrics.keySpacing / 2, y: 0,
            width: bounds.width - switchFrame.minX + metrics.keySpacing / 2,
            height: bounds.height)
        if switchTouchFrame.contains(point) {
            let key = ExtraKeys.switchKey(toSystemKeyboard: !(keyboard?.usesSystemKeyboard ?? false))
            return KeyTouches.Hit(index: keys.count, key: key, frame: switchFrame, touchFrame: switchTouchFrame)
        }
        guard scrollArea.frame.contains(point) else { return nil }
        let offset = CGPoint(x: scrollArea.frame.minX - scrollView.contentOffset.x, y: scrollArea.frame.minY)
        let inKeys = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
        guard var hit = geometry.hit(at: inKeys) else { return nil }
        hit.frame = hit.frame.offsetBy(dx: offset.x, dy: offset.y)
        hit.touchFrame = hit.touchFrame.offsetBy(dx: offset.x, dy: offset.y).intersection(scrollArea.frame)
        return hit
    }

    private func render() {
        guard let keyboard else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pressed = touches.pressedIndexes
        let changed = needsFullRender ? Set(0...keys.count) : pressed.symmetricDifference(drawnPressed)
        needsFullRender = false
        drawnPressed = pressed
        let scale = traitCollection.displayScale
        for index in changed where geometry.caps.indices.contains(index) {
            let cap = geometry.caps[index]
            let face = keyboard.face(
                for: cap.key, frame: cap.frame, isPressed: pressed.contains(index), metrics: metrics)
            caps[index].draw(face, frame: cap.frame, cornerRadius: metrics.cornerRadius, scale: scale)
        }
        if changed.contains(keys.count) {
            let switchKey = ExtraKeys.switchKey(toSystemKeyboard: !keyboard.usesSystemKeyboard)
            let switchFace = keyboard.face(
                for: switchKey, frame: switchKeyView.bounds, isPressed: pressed.contains(keys.count), metrics: metrics)
            switchCap.draw(switchFace, frame: switchKeyView.bounds, cornerRadius: metrics.cornerRadius, scale: scale)
        }
        CATransaction.commit()
    }

    private func touchesChanged() {
        render()
        scheduleTick()
    }

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

    /// The row's keys as VoiceOver finds them: the scrolling keys, then the switch key.
    var keyElements: [KeyAccessibilityElement] { elements + [switchElement] }

    /// The key that switches keyboards, which VoiceOver moves to after a switch.
    var switchAccessibilityElement: KeyAccessibilityElement { switchElement }

    /// One element per key, made once, so that the one VoiceOver is on stays when the text size
    /// changes the row.
    private func makeAccessibilityElements() {
        elements = keys.map { key in
            let element = KeyAccessibilityElement(accessibilityContainer: keysView)
            element.press = { [weak self] in self?.keyboard?.press(key) }
            if key.action == .arrows {
                // The swipe key takes drags: VoiceOver passes them on, and offers each arrow as an
                // action for those who do not drag. Its taps send nothing with VoiceOver.
                element.accessibilityHint = String(
                    localized: "Drag in a direction to send arrow keys. The arrows are also actions.")
            }
            return element
        }
        keysView.accessibilityElements = elements
        switchElement.press = { [weak self] in
            guard let keyboard = self?.keyboard else { return }
            keyboard.press(ExtraKeys.switchKey(toSystemKeyboard: !keyboard.usesSystemKeyboard))
        }
        switchKeyView.accessibilityElements = [switchElement]
        accessibilityElements = [scrollView, switchKeyView]
    }

    /// The keys' places, names, states and actions, as they change with the text size and the
    /// modifiers.
    private func updateAccessibility() {
        guard let keyboard else { return }
        for (element, cap) in zip(elements, geometry.caps) {
            element.accessibilityFrameInContainerSpace = cap.touchFrame
            element.accessibilityLabel = keyboard.spokenLabel(for: cap.key)
            element.accessibilityValue = keyboard.spokenValue(for: cap.key)
            element.accessibilityUserInputLabels = keyboard.userInputLabels(for: cap.key)
            if cap.key.action == .arrows {
                element.accessibilityTraits = [.keyboardKey, .allowsDirectInteraction]
                // A touch made for the key lands on its dot, which sends nothing.
                element.activationPointInContainerSpace = CGPoint(x: cap.frame.midX, y: cap.frame.midY)
                element.accessibilityCustomActions = SwipeKey.Direction.allCases.map { direction in
                    UIAccessibilityCustomAction(name: direction.spokenName) { [weak self] _ in
                        self?.keyboard?.sendArrow(direction)
                        return true
                    }
                }
            } else {
                element.accessibilityTraits = .keyboardKey
                element.accessibilityCustomActions = keyboard.accessibilityCustomActions(for: cap.key)
            }
        }
        let switchKey = ExtraKeys.switchKey(toSystemKeyboard: !keyboard.usesSystemKeyboard)
        switchElement.accessibilityLabel = keyboard.spokenLabel(for: switchKey)
        switchElement.accessibilityUserInputLabels = keyboard.userInputLabels(for: switchKey)
        switchElement.accessibilityTraits = .keyboardKey
        switchElement.accessibilityFrameInContainerSpace = switchKeyView.bounds
    }
}

/// The row's scroll view, which leaves a drag that starts on the swipe key to the key.
final class ExtraKeysScrollView: UIScrollView {
    /// Whether a drag that starts at a point, in the row's coordinates, may scroll the row.
    var startsDrag: (CGPoint) -> Bool = { _ in true }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === panGestureRecognizer, let row = superview?.superview {
            let start = recognizer.location(in: row)
            let translation = panGestureRecognizer.translation(in: row)
            if !startsDrag(CGPoint(x: start.x - translation.x, y: start.y - translation.y)) {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(recognizer)
    }
}

extension SwipeKey.Direction {
    /// The arrow's name, for VoiceOver's actions on the swipe key.
    var spokenName: String {
        switch self {
        case .up: String(localized: "Up Arrow")
        case .down: String(localized: "Down Arrow")
        case .left: String(localized: "Left Arrow")
        case .right: String(localized: "Right Arrow")
        }
    }
}
