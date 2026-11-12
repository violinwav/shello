import Foundation

/// A modifier key that stays down for the user (GLOSSARY, Sticky modifier): one tap arms it for the
/// next key, a quick second tap locks it until it is tapped again, and a later tap on an armed key
/// lets it go (README section 6). Shift works the same way on the letters, as Caps Lock when locked.
nonisolated public struct StickyModifier: Sendable {
    public enum State: Equatable, Sendable {
        case off
        /// For the next key only.
        case armed
        /// For every key until the modifier is tapped again.
        case locked
    }

    public private(set) var state = State.off
    /// When the modifier was armed, for telling a double tap from two taps.
    private var armedAt: TimeInterval?

    /// How soon the second tap of a double tap follows the first, in seconds.
    static let doubleTapInterval: TimeInterval = 0.35

    public init() {}

    public var isActive: Bool { state != .off }

    /// The modifier key was tapped at `time`, in seconds on any clock that only goes forward.
    public mutating func tap(at time: TimeInterval) {
        switch state {
        case .off:
            state = .armed
            armedAt = time
        case .armed:
            let isDoubleTap = armedAt.map { time - $0 <= Self.doubleTapInterval } ?? false
            state = isDoubleTap ? .locked : .off
            armedAt = nil
        case .locked:
            state = .off
        }
    }

    /// A key used the modifier: an armed modifier lets go, a locked one stays.
    public mutating func use() {
        guard state == .armed else { return }
        state = .off
        armedAt = nil
    }

    /// Locks the modifier, or turns it off, at once: for VoiceOver and Switch Control, with which
    /// a double tap is two activations too far apart.
    public mutating func set(locked: Bool) {
        state = locked ? .locked : .off
        armedAt = nil
    }
}

/// The sticky Control and Alt of a terminal, for the badge that shows them over the terminal.
nonisolated public struct ArmedModifiers: Equatable, Sendable {
    public var control: StickyModifier.State
    public var alt: StickyModifier.State

    public init(control: StickyModifier.State = .off, alt: StickyModifier.State = .off) {
        self.control = control
        self.alt = alt
    }

    public var isEmpty: Bool { control == .off && alt == .off }

    /// What the badge says, after the UI design: "CTRL armed · next key sends ⌃", or each modifier
    /// with its state, such as "CTRL locked · ALT armed". Nil when neither is on.
    public var summary: String? {
        let parts = [("CTRL", control), ("ALT", alt)].compactMap { name, state -> String? in
            switch state {
            case .off: nil
            case .armed: "\(name) \(String(localized: "armed"))"
            case .locked: "\(name) \(String(localized: "locked"))"
            }
        }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1, control == .armed {
            return parts[0] + " · " + String(localized: "next key sends ⌃")
        }
        if parts.count == 1, alt == .armed {
            return parts[0] + " · " + String(localized: "next key sends Esc first")
        }
        return parts.joined(separator: " · ")
    }
}
