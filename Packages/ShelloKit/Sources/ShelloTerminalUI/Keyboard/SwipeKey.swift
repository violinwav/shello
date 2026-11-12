import CoreGraphics
import Foundation

/// The swipe key's drag (GLOSSARY, Swipe key): once the finger is past a small dead zone, it sends
/// an arrow in the direction of the drag at once, then repeats it, faster the further the finger
/// is from where it started (README section 6). The speed setting scales the rate. A tap sends
/// the arrow drawn where the finger came down, for those who cannot drag.
///
/// It runs on the times of the touches, in seconds, and needs a tick at `deadline` to repeat.
nonisolated struct SwipeKey {
    enum Direction: CaseIterable, Sendable {
        case up
        case down
        case left
        case right

        var key: TerminalKey {
            switch self {
            case .up: .up
            case .down: .down
            case .left: .left
            case .right: .right
            }
        }
    }

    /// How far the finger moves, in points, before the first arrow: a touch that wobbles sends
    /// nothing.
    static let deadZone: CGFloat = 12
    /// Arrows per second just past the dead zone, at speed 1: slow enough to step one at a time.
    static let baseRate: Double = 4
    /// Arrows per second more for each point further out, at speed 1.
    static let rateGain: Double = 0.25
    /// The most arrows per second, at any speed.
    static let maximumRate: Double = 60

    /// The speed setting, 1 by default (KeyboardPreferences.swipeSpeeds).
    var speed: Double

    private var origin: CGPoint?
    private var location = CGPoint.zero
    private(set) var direction: Direction?
    /// When the last arrow went.
    private var lastArrow: TimeInterval?
    /// Whether the drag has sent an arrow: a touch that has not is a tap.
    private(set) var hasSent = false

    init(speed: Double = 1) {
        self.speed = speed
    }

    /// The arrow a tap at `point` sends on a key drawn in `frame`: the one of the four drawn on the
    /// side the finger is on, or nil at the dot in the middle.
    static func direction(ofTapAt point: CGPoint, in frame: CGRect) -> Direction? {
        let dx = (point.x - frame.midX) / max(frame.width / 2, 1)
        let dy = (point.y - frame.midY) / max(frame.height / 2, 1)
        guard max(abs(dx), abs(dy)) > 0.2 else { return nil }
        if abs(dx) >= abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .up : .down
    }

    /// The direction of a drag by `translation`, or nil inside the dead zone. The axis the drag
    /// went further along wins; along the diagonal, the drag keeps `current`, so that it does not
    /// flip back and forth.
    static func direction(of translation: CGVector, current: Direction? = nil) -> Direction? {
        let horizontal = abs(translation.dx)
        let vertical = abs(translation.dy)
        guard max(horizontal, vertical) > deadZone else { return nil }
        let isHorizontal: Bool
        switch current {
        case .left, .right: isHorizontal = horizontal * 1.25 >= vertical
        case .up, .down: isHorizontal = horizontal > vertical * 1.25
        case nil: isHorizontal = horizontal >= vertical
        }
        if isHorizontal {
            return translation.dx < 0 ? .left : .right
        }
        return translation.dy < 0 ? .up : .down
    }

    /// Arrows per second with the finger `distance` points from where it started.
    func rate(atDistance distance: CGFloat) -> Double {
        let past = max(Double(distance - Self.deadZone), 0)
        return min((Self.baseRate + Self.rateGain * past) * speed, Self.maximumRate)
    }

    /// When the next arrow is due, while the finger is past the dead zone.
    var deadline: TimeInterval? {
        guard direction != nil, let lastArrow else { return nil }
        return lastArrow + interval
    }

    mutating func began(at point: CGPoint) {
        origin = point
        location = point
        direction = nil
        lastArrow = nil
        hasSent = false
    }

    /// The finger moved to `point` at `time`. Returns the arrow to send at once: the first one
    /// past the dead zone, or the first one in a new direction.
    mutating func moved(to point: CGPoint, at time: TimeInterval) -> Direction? {
        guard let origin else { return nil }
        location = point
        let translation = CGVector(dx: point.x - origin.x, dy: point.y - origin.y)
        let newDirection = Self.direction(of: translation, current: direction)
        guard newDirection != direction else { return nil }
        direction = newDirection
        lastArrow = newDirection == nil ? nil : time
        if newDirection != nil {
            hasSent = true
        }
        return newDirection
    }

    /// Returns the arrow due at `time`, if any.
    mutating func tick(at time: TimeInterval) -> Direction? {
        guard let direction, let deadline, time >= deadline else { return nil }
        // After a stall, one arrow, then the rate again: never a burst of arrows.
        lastArrow = max(deadline, time - interval / 2)
        hasSent = true
        return direction
    }

    mutating func ended() {
        origin = nil
        direction = nil
        lastArrow = nil
        hasSent = false
    }

    /// The time between arrows where the finger is now.
    private var interval: TimeInterval {
        guard let origin, let direction else { return .infinity }
        let distance: CGFloat =
            switch direction {
            case .left, .right: abs(location.x - origin.x)
            case .up, .down: abs(location.y - origin.y)
            }
        return 1 / rate(atDistance: distance)
    }
}
