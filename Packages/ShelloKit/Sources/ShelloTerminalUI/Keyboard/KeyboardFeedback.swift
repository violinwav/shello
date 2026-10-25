import UIKit

/// What the keyboard gives back for a key other than what it types: a light haptic tap, which the
/// user can turn off, the keyboard click, which follows the Settings app's Keyboard Clicks,
/// VoiceOver's announcements of a modifier's state and of a new layer, and where VoiceOver goes when
/// the keys on screen change. Tests replace it.
struct KeyboardFeedback {
    /// A finger came down on a key: gets the haptic engine ready, so that the tap comes on time.
    var prepare: () -> Void
    var haptic: () -> Void
    var click: () -> Void
    var isVoiceOverRunning: () -> Bool
    var announce: (String) -> Void
    /// The element VoiceOver is on, if VoiceOver can say: none on the system keyboard, whose keys
    /// are another process's.
    var voiceOverFocus: () -> AnyObject?
    /// The keys on screen changed: VoiceOver goes to `element`, or stays where it is for nil.
    var layoutChanged: (_ element: AnyObject?) -> Void

    /// The device's haptics and clicks, for keys on `view`. Announcements wait for VoiceOver to
    /// finish saying the key.
    static func system(for view: UIView) -> KeyboardFeedback {
        let generator = UIImpactFeedbackGenerator(style: .light, view: view)
        return KeyboardFeedback(
            prepare: { generator.prepare() },
            haptic: { generator.impactOccurred() },
            click: { UIDevice.current.playInputClick() },
            isVoiceOverRunning: { UIAccessibility.isVoiceOverRunning },
            announce: { text in
                let queued = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
                UIAccessibility.post(notification: .announcement, argument: queued)
            },
            voiceOverFocus: {
                UIAccessibility.focusedElement(using: .notificationVoiceOver).map { $0 as AnyObject }
            },
            layoutChanged: { element in
                UIAccessibility.post(notification: .layoutChanged, argument: element)
            })
    }
}

/// The Shello keyboard's settings (README section 6), part of the terminal's preferences.
nonisolated public struct KeyboardPreferences: Equatable, Sendable {
    /// The letters layout, or nil to follow the first keyboard in the Settings app.
    public var letters: LettersLayout.ID?
    /// A haptic tap per key, on by default.
    public var haptics: Bool
    /// How fast the swipe key sends arrows, as a multiple of the normal speed, within
    /// `swipeSpeeds` in steps of a quarter.
    public var swipeSpeed: Double {
        didSet { swipeSpeed = Self.clampedSwipeSpeed(swipeSpeed) }
    }
    /// Whether the extra keys row stays while a hardware keyboard is attached, which hides the Shello
    /// keyboard: for the keys a hardware keyboard may lack, such as esc and the swipe key. On by
    /// default.
    public var showsExtraKeysRowWithHardwareKeyboard: Bool

    public init(
        letters: LettersLayout.ID? = nil, haptics: Bool = true, swipeSpeed: Double = 1,
        showsExtraKeysRowWithHardwareKeyboard: Bool = true
    ) {
        self.letters = letters
        self.haptics = haptics
        self.swipeSpeed = Self.clampedSwipeSpeed(swipeSpeed)
        self.showsExtraKeysRowWithHardwareKeyboard = showsExtraKeysRowWithHardwareKeyboard
    }

    /// The swipe key's speeds Settings offers: as the UI design's slider, from half to three
    /// times the normal speed.
    public static let swipeSpeeds: ClosedRange<Double> = 0.5...3

    /// `speed` in quarter steps within `swipeSpeeds`.
    public static func clampedSwipeSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        return min(max((speed * 4).rounded() / 4, swipeSpeeds.lowerBound), swipeSpeeds.upperBound)
    }
}

/// The primary languages of the keyboards in the Settings app, in their order, such as "de-CH".
enum KeyboardLanguages {
    static func current() -> [String] {
        UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
    }
}

extension LettersLayout.ID {
    /// The layout that follows the first keyboard in the Settings app, which Automatic means.
    public static var automatic: Self {
        LettersLayout.automatic(forKeyboardLanguages: KeyboardLanguages.current())
    }
}
