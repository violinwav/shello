import UIKit

/// The one gesture recognizer of a keyboard (STACK section 7.5). It hands every finger to the
/// keyboard's `KeyTouches`, which tells taps, flicks, long-presses, repeats and the swipe key apart,
/// so a key costs no recognizer or view of its own.
///
/// On the Shello keyboard it claims its touches at once. On the extra keys row, which scrolls, it
/// claims only the swipe key's: a tap elsewhere waits for the finger to lift, and a drag sideways
/// scrolls the row instead, which takes the touch away from the key.
final class KeyboardGestureRecognizer: UIGestureRecognizer {
    private let touches: KeyTouches
    /// Whether every touch is claimed as it begins.
    var claimsTouchesAtOnce = true
    /// Tells a touch that is not to type, such as one that stops the row from gliding.
    var ignoresTouch: (UITouch) -> Bool = { _ in false }
    /// Called after the touches changed: the view draws the keys and schedules the next tick.
    var onChange: () -> Void = {}

    init(touches: KeyTouches) {
        self.touches = touches
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            if ignoresTouch(touch) {
                ignore(touch, for: event)
                continue
            }
            self.touches.began(ObjectIdentifier(touch), at: touch.location(in: view), time: touch.timestamp)
        }
        if state == .possible, claimsTouchesAtOnce || self.touches.isSwiping {
            state = .began
        } else if state == .began || state == .changed {
            state = .changed
        }
        onChange()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            self.touches.moved(ObjectIdentifier(touch), to: touch.location(in: view), time: touch.timestamp)
        }
        if state == .began || state == .changed {
            state = .changed
        }
        onChange()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            self.touches.ended(ObjectIdentifier(touch), at: touch.location(in: view), time: touch.timestamp)
        }
        if !self.touches.isTracking {
            state = .ended
        } else if state == .began || state == .changed {
            state = .changed
        }
        onChange()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            self.touches.cancelled(ObjectIdentifier(touch))
        }
        if !self.touches.isTracking {
            state = state == .possible ? .failed : .cancelled
        }
        onChange()
    }

    /// Called once the gesture ended, failed or was taken over by another recognizer, such as the
    /// row's scrolling: whatever is still down types nothing.
    override func reset() {
        super.reset()
        touches.cancelAll()
        onChange()
    }
}
