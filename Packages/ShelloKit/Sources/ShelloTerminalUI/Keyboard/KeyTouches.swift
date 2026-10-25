import CoreGraphics
import Foundation

/// The touches on one keyboard, from its one gesture recognizer (STACK section 7.5): a tap types a
/// key as the finger lifts, a flick down types the symbol in the key's corner, a long-press offers
/// the key's alternates, Delete and Space repeat while held, and the swipe key sends arrows while
/// the finger drags across it, or one arrow for a tap. Each finger is followed on its own. When a
/// key is touched while another is still down, as two thumbs do when typing fast, the one down
/// first types first.
///
/// It works in the keyboard's coordinates and on the times of the touches, and needs `tick(at:)`
/// at `deadline` for long-presses and repeats, so tests drive it without UIKit.
final class KeyTouches {
    /// The key under a point: its index in the keyboard, where it is drawn, and the area that
    /// counts as touching it, which reaches into the gaps around it.
    struct Hit: Equatable {
        var index: Int
        var key: KeyboardKey
        var frame: CGRect
        var touchFrame: CGRect
    }

    enum Event: Equatable {
        /// A finger came down on `key`.
        case touchDown(KeyboardKey)
        /// `key` acts, at the time of the touch that made it act. `text` replaces the key's own
        /// for a flick or an alternate; `isRepeat` marks a repeat while the key is held.
        case press(KeyboardKey, text: String?, isRepeat: Bool, time: TimeInterval)
        /// The swipe key sends an arrow.
        case arrow(SwipeKey.Direction, time: TimeInterval)
        /// A drag of the swipe key ended.
        case swipeEnded
        /// The modifier `key` was held on its own long enough to lock it.
        case lock(KeyboardKey, time: TimeInterval)
    }

    /// The bubble over a key: the symbol of a flick, or the alternates of a long-press with the
    /// one under the finger selected.
    struct Callout: Equatable {
        var keyIndex: Int
        var items: [String]
        var frames: [CGRect]
        var selection: Int
        var isFlick: Bool
    }

    /// How long a finger rests on a key before its alternates show.
    static let longPressDelay: TimeInterval = 0.4
    /// How far a finger may wander before a long-press no longer counts, in points.
    static let longPressSlop: CGFloat = 10
    /// How long Delete and Space are held before they repeat, and how often they repeat then: as
    /// SwiftTerm repeats a hardware key.
    static let repeatDelay: TimeInterval = 0.4
    static let repeatInterval: TimeInterval = 0.1
    /// How long a modifier is held, with no other key, to lock it: for those who cannot tap twice
    /// within a double tap's time.
    static let lockDelay: TimeInterval = 0.5

    /// Finds the key under a point.
    var hitTest: (CGPoint) -> Hit? = { _ in nil }
    /// Receives what the touches do, in order.
    var onEvent: (Event) -> Void = { _ in }
    /// The keyboard's bounds, which a callout stays inside sideways.
    var bounds = CGRect.zero
    /// The swipe key's speed setting.
    var swipeSpeed: Double = 1
    /// Whether a tap on the swipe key sends the arrow it lands on. Not with VoiceOver, which passes
    /// its touches on the key straight through: its double tap would send arrows the user did not
    /// hear.
    var tapsSendArrows: () -> Bool = { true }

    private enum Phase: Equatable {
        /// Types its key when the finger lifts.
        case pending
        /// Pulled down far enough: types the key's corner symbol when the finger lifts.
        case flicked
        /// Shows the alternates; types the selected one when the finger lifts.
        case alternates(Callout)
        /// Repeats its key at `next`.
        case repeating(next: TimeInterval)
        case swiping
        /// A modifier, down since `since` with no other key: it locks if held long enough.
        case holding(since: TimeInterval)
        /// Has acted, and waits for the finger to lift.
        case done
    }

    private struct Touch {
        var hit: Hit
        var start: CGPoint
        var location: CGPoint
        var longPressAt: TimeInterval?
        var phase: Phase
        var swipe: SwipeKey?
        /// The order the fingers came down in.
        var order: Int
    }

    private var touches: [ObjectIdentifier: Touch] = [:]
    private var touchCount = 0

    var isTracking: Bool { !touches.isEmpty }

    /// Whether a finger is on the swipe key.
    var isSwiping: Bool { touches.values.contains { $0.phase == .swiping } }

    /// The keys a finger is on, to draw pressed.
    var pressedIndexes: Set<Int> { Set(touches.values.map(\.hit.index)) }

    /// The bubble to draw: that of the last finger to flick or long-press.
    var callout: Callout? {
        let touch = touches.values.sorted { $0.order > $1.order }.first { touch in
            switch touch.phase {
            case .flicked, .alternates: true
            default: false
            }
        }
        guard let touch else { return nil }
        switch touch.phase {
        case .alternates(let callout):
            return callout
        case .flicked:
            guard let flick = touch.hit.key.flick else { return nil }
            return Callout(
                keyIndex: touch.hit.index, items: [flick],
                frames: Self.calloutFrames(1, over: touch.hit.frame, in: bounds),
                selection: 0, isFlick: true)
        default:
            return nil
        }
    }

    /// When `tick(at:)` is due next: a long-press, a repeat or the swipe key's next arrow.
    var deadline: TimeInterval? {
        touches.values.compactMap { touch -> TimeInterval? in
            switch touch.phase {
            case .pending: touch.longPressAt
            case .repeating(let next): next
            case .swiping: touch.swipe?.deadline
            default: nil
            }
        }.min()
    }

    func began(_ id: ObjectIdentifier, at point: CGPoint, time: TimeInterval) {
        guard let hit = hitTest(point) else { return }
        // A key still down types before this one, and a modifier held for it no longer locks.
        for (otherID, other) in touches.sorted(by: { $0.value.order < $1.value.order }) {
            switch other.phase {
            case .pending, .flicked:
                finish(otherID, at: time)
                touches[otherID]?.phase = .done
            case .holding:
                touches[otherID]?.phase = .done
            default:
                break
            }
        }
        onEvent(.touchDown(hit.key))
        var touch = Touch(hit: hit, start: point, location: point, phase: .pending, order: touchCount)
        touchCount += 1
        if hit.key.action == .arrows {
            var swipe = SwipeKey(speed: swipeSpeed)
            swipe.began(at: point)
            touch.swipe = swipe
            touch.phase = .swiping
        } else if hit.key.actsOnTouchDown {
            onEvent(.press(hit.key, text: nil, isRepeat: false, time: time))
            if hit.key.repeats {
                touch.phase = .repeating(next: time + Self.repeatDelay)
            } else if case .modifier = hit.key.action {
                touch.phase = .holding(since: time)
            } else {
                touch.phase = .done
            }
        } else if !Self.longPressItems(of: hit.key).isEmpty {
            touch.longPressAt = time + Self.longPressDelay
        }
        touches[id] = touch
    }

    func moved(_ id: ObjectIdentifier, to point: CGPoint, time: TimeInterval) {
        guard var touch = touches[id] else { return }
        touch.location = point
        switch touch.phase {
        case .pending, .flicked:
            if touch.hit.key.flick != nil, Self.isFlick(from: touch.start, to: point, keyHeight: touch.hit.frame.height)
            {
                touch.phase = .flicked
                touch.longPressAt = nil
            } else {
                touch.phase = .pending
                retarget(&touch, at: point, time: time)
            }
        case .alternates(var callout):
            callout.selection = Self.selection(in: callout, at: point)
            touch.phase = .alternates(callout)
        case .swiping:
            if let arrow = touch.swipe?.moved(to: point, at: time) {
                onEvent(.arrow(arrow, time: time))
            }
        case .repeating, .holding, .done:
            break
        }
        touches[id] = touch
    }

    func ended(_ id: ObjectIdentifier, at point: CGPoint, time: TimeInterval) {
        if touches[id]?.phase != .swiping {
            moved(id, to: point, time: time)
        }
        finish(id, at: time)
        touches[id] = nil
    }

    /// A touch the system took away, as a scroll of the extra keys row does: it types nothing.
    func cancelled(_ id: ObjectIdentifier) {
        guard let touch = touches.removeValue(forKey: id) else { return }
        if touch.phase == .swiping {
            onEvent(.swipeEnded)
        }
    }

    func cancelAll() {
        for id in touches.keys {
            cancelled(id)
        }
    }

    func tick(at time: TimeInterval) {
        for id in touches.keys.sorted(by: { touches[$0]!.order < touches[$1]!.order }) {
            guard var touch = touches[id] else { continue }
            switch touch.phase {
            case .pending:
                guard let longPressAt = touch.longPressAt, time >= longPressAt else { break }
                touch.longPressAt = nil
                let items = Self.longPressItems(of: touch.hit.key)
                var callout = Callout(
                    keyIndex: touch.hit.index, items: items,
                    frames: Self.calloutFrames(items.count, over: touch.hit.frame, in: bounds), selection: 0,
                    isFlick: false)
                callout.selection = Self.selection(in: callout, at: touch.location)
                touch.phase = .alternates(callout)
            case .repeating(let next):
                guard time >= next else { break }
                onEvent(.press(touch.hit.key, text: nil, isRepeat: true, time: time))
                // After a stall, one repeat, then the rate again: never a burst.
                touch.phase = .repeating(next: max(next + Self.repeatInterval, time + Self.repeatInterval / 2))
            case .swiping:
                if let arrow = touch.swipe?.tick(at: time) {
                    onEvent(.arrow(arrow, time: time))
                }
            default:
                break
            }
            touches[id] = touch
        }
    }

    /// Types what the touch `id` stands for, as its finger lifts.
    private func finish(_ id: ObjectIdentifier, at time: TimeInterval) {
        guard let touch = touches[id] else { return }
        switch touch.phase {
        case .pending:
            onEvent(.press(touch.hit.key, text: nil, isRepeat: false, time: time))
        case .flicked:
            onEvent(.press(touch.hit.key, text: touch.hit.key.flick, isRepeat: false, time: time))
        case .alternates(let callout):
            onEvent(.press(touch.hit.key, text: callout.items[callout.selection], isRepeat: false, time: time))
        case .swiping:
            // A tap that did not drag sends the arrow it landed on.
            if touch.swipe?.hasSent == false, tapsSendArrows(),
                let direction = SwipeKey.direction(ofTapAt: touch.start, in: touch.hit.frame)
            {
                onEvent(.arrow(direction, time: time))
            }
            onEvent(.swipeEnded)
        case .holding(let since):
            if time - since >= Self.lockDelay {
                onEvent(.lock(touch.hit.key, time: time))
            }
        case .repeating, .done:
            break
        }
    }

    /// A finger that slides off its key onto another types that one instead, as on the system
    /// keyboard. Only keys that type as the finger lifts take it over. A finger that wanders too
    /// far no longer long-presses.
    private func retarget(_ touch: inout Touch, at point: CGPoint, time: TimeInterval) {
        if !touch.hit.touchFrame.contains(point), let hit = hitTest(point), hit.index != touch.hit.index,
            !hit.key.actsOnTouchDown, hit.key.action != .arrows
        {
            touch.hit = hit
            touch.start = point
            touch.longPressAt = Self.longPressItems(of: hit.key).isEmpty ? nil : time + Self.longPressDelay
        } else if touch.longPressAt != nil, hypot(point.x - touch.start.x, point.y - touch.start.y) > Self.longPressSlop
        {
            touch.longPressAt = nil
        }
    }

    /// What a long-press on `key` offers: the key's own text, its alternates, then its corner
    /// symbol, for those who long-press rather than flick. Nothing for other keys.
    static func longPressItems(of key: KeyboardKey) -> [String] {
        guard case .text(let text) = key.action else { return [] }
        let items = key.alternates + (key.flick.map { [$0] } ?? [])
        return items.isEmpty ? [] : [text] + items
    }

    /// Whether a finger that came down at `start` and is now at `point` flicked down: further than
    /// about half a key, and more down than sideways.
    static func isFlick(from start: CGPoint, to point: CGPoint, keyHeight: CGFloat) -> Bool {
        let down = point.y - start.y
        return down > max(keyHeight * 0.4, 16) && down > abs(point.x - start.x)
    }

    /// Frames for `count` items in a row above `key`: from the key rightwards, or leftwards when
    /// that would leave `bounds`, and narrower when they would not fit at all.
    static func calloutFrames(_ count: Int, over key: CGRect, in bounds: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        var width = max(key.width, 30)
        if bounds.width > 0 {
            width = min(width, bounds.width / CGFloat(count))
        }
        let total = width * CGFloat(count)
        var x = key.minX
        if bounds.width > 0 {
            if x + total > bounds.maxX {
                x = key.maxX - total
            }
            x = min(max(x, bounds.minX), bounds.maxX - total)
        }
        let y = key.minY - key.height - 8
        return (0..<count).map { CGRect(x: x + width * CGFloat($0), y: y, width: width, height: key.height) }
    }

    /// The item of `callout` under `point`, or the nearest one.
    static func selection(in callout: Callout, at point: CGPoint) -> Int {
        callout.frames.firstIndex { point.x < $0.maxX } ?? max(callout.frames.count - 1, 0)
    }
}
