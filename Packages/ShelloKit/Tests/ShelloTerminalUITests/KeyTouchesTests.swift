import Testing
import UIKit

@testable import ShelloTerminalUI

/// The keyboard's touches (README section 6): a tap types on lift, a flick types the corner
/// symbol, a long-press offers alternates, Delete and Space repeat, fast typing keeps its order,
/// and the swipe key sends arrows.
@MainActor
@Suite struct KeyTouchesTests {
    /// The QWERTY letters on a 390-point keyboard, with the swipe key of the extra keys row.
    private let geometry = KeyboardGeometry(
        rows: KeyboardLayer.letters(.qwerty).rows, width: 390,
        metrics: KeyboardMetrics(
            keyHeight: 44, keySpacing: 5, rowSpacing: 10, insets: UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6),
            cornerRadius: 7, labelScale: 1))
    private let touches = KeyTouches()
    private let recorder = EventRecorder()
    /// Touch identities, which the engine tells apart by object.
    private let fingers = (0..<3).map { _ in NSObject() }

    init() {
        let geometry = geometry
        touches.hitTest = { geometry.hit(at: $0) }
        touches.bounds = CGRect(origin: .zero, size: geometry.size)
        let recorder = recorder
        touches.onEvent = { recorder.events.append($0) }
    }

    private func finger(_ index: Int) -> ObjectIdentifier {
        ObjectIdentifier(fingers[index])
    }

    /// The middle of the key labelled `label`.
    private func center(_ label: String) -> CGPoint {
        let cap = geometry.caps.first { $0.key.label == label }!
        return CGPoint(x: cap.frame.midX, y: cap.frame.midY)
    }

    @Test func tapTypesAsTheFingerLifts() {
        touches.began(finger(0), at: center("q"), time: 1)
        #expect(recorder.typed.isEmpty)
        #expect(touches.pressedIndexes == [0])
        touches.ended(finger(0), at: center("q"), time: 1.05)
        #expect(recorder.typed == ["q"])
        #expect(recorder.pressTimes == [1.05])
        #expect(touches.pressedIndexes.isEmpty)
    }

    @Test func flickDownTypesTheCornerSymbol() {
        let start = center("w")
        touches.began(finger(0), at: start, time: 1)
        touches.moved(finger(0), to: CGPoint(x: start.x + 2, y: start.y + 25), time: 1.05)
        #expect(touches.callout?.items == ["2"])
        #expect(touches.callout?.isFlick == true)
        touches.ended(finger(0), at: CGPoint(x: start.x + 2, y: start.y + 26), time: 1.08)
        #expect(recorder.typed == ["2"])
    }

    /// Back up before lifting, the key types its own character.
    @Test func flickTakenBackTypesTheKey() {
        let start = center("w")
        touches.began(finger(0), at: start, time: 1)
        touches.moved(finger(0), to: CGPoint(x: start.x, y: start.y + 25), time: 1.05)
        touches.moved(finger(0), to: CGPoint(x: start.x, y: start.y + 4), time: 1.1)
        touches.ended(finger(0), at: CGPoint(x: start.x, y: start.y + 4), time: 1.12)
        #expect(recorder.typed == ["w"])
    }

    @Test func longPressOffersTheAlternatesAndTypesTheOneChosen() throws {
        let start = center("e")
        touches.began(finger(0), at: start, time: 1)
        #expect(touches.deadline == 1 + KeyTouches.longPressDelay)
        touches.tick(at: 1.45)
        let callout = try #require(touches.callout)
        // The corner symbol last, for those who long-press rather than flick.
        #expect(callout.items == ["e", "è", "é", "ê", "ë", "ē", "ė", "ę", "3"])
        #expect(callout.selection == 0)
        // Above the key, never past the keyboard's edges.
        #expect(callout.frames[0].maxY < geometry.caps[2].frame.minY)
        #expect(callout.frames.allSatisfy { $0.minX >= 0 && $0.maxX <= 390 })
        touches.moved(finger(0), to: CGPoint(x: callout.frames[2].midX, y: start.y), time: 1.6)
        #expect(touches.callout?.selection == 2)
        touches.ended(finger(0), at: CGPoint(x: callout.frames[2].midX, y: start.y), time: 1.7)
        #expect(recorder.typed == ["é"])
    }

    /// A key with a corner symbol and no alternates offers its symbol to a long-press.
    @Test func longPressOnAKeyWithoutAlternatesOffersItsSymbol() {
        touches.began(finger(0), at: center("q"), time: 1)
        touches.tick(at: 1.5)
        #expect(touches.callout?.items == ["q", "1"])
    }

    /// A long-press near the right edge grows its alternates leftwards.
    @Test func calloutStaysOnTheKeyboard() {
        touches.began(finger(0), at: center("o"), time: 1)
        touches.tick(at: 1.5)
        let frames = touches.callout?.frames ?? []
        #expect(frames.count == 10)
        #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= 390 })
    }

    /// Delete acts at once, then repeats every 0.1 seconds after 0.4, until the finger lifts.
    @Test func deleteRepeatsWhileHeld() {
        touches.began(finger(0), at: center("⌫"), time: 1)
        #expect(recorder.presses.count == 1)
        touches.tick(at: 1.39)
        #expect(recorder.presses.count == 1)
        for tick in stride(from: 1.4, through: 1.75, by: 0.05) {
            touches.tick(at: tick)
        }
        // At 1.4, 1.5, 1.6 and 1.7.
        #expect(recorder.presses.map(\.isRepeat) == [false, true, true, true, true])
        touches.ended(finger(0), at: center("⌫"), time: 1.76)
        touches.tick(at: 3)
        #expect(recorder.presses.count == 5)
    }

    @Test func spaceRepeatsToo() {
        touches.began(finger(0), at: center("space"), time: 1)
        touches.tick(at: 1.41)
        touches.ended(finger(0), at: center("space"), time: 1.42)
        #expect(recorder.typed == [" ", " "])
    }

    /// Two thumbs: the key still down types as soon as the next is touched, so the order holds.
    @Test func fastTypingKeepsItsOrder() {
        touches.began(finger(0), at: center("a"), time: 1)
        touches.began(finger(1), at: center("s"), time: 1.03)
        #expect(recorder.typed == ["a"])
        touches.ended(finger(0), at: center("a"), time: 1.05)
        touches.ended(finger(1), at: center("s"), time: 1.08)
        #expect(recorder.typed == ["a", "s"])
    }

    /// A finger that slides onto the next key types that one.
    @Test func slidingOntoAnotherKeyTypesIt() {
        touches.began(finger(0), at: center("g"), time: 1)
        touches.moved(finger(0), to: center("h"), time: 1.05)
        touches.ended(finger(0), at: center("h"), time: 1.1)
        #expect(recorder.typed == ["h"])
    }

    /// Shift acts as it is touched, so that it can be held for the next key.
    @Test func modifiersActAsTheyAreTouched() {
        touches.began(finger(0), at: center("⇧"), time: 1)
        #expect(recorder.presses.map(\.key.action) == [.modifier(.shift)])
        touches.ended(finger(0), at: center("⇧"), time: 1.1)
        #expect(recorder.presses.count == 1)
    }

    /// A touch the system takes away, as a scroll does, types nothing.
    @Test func cancelledTouchTypesNothing() {
        touches.began(finger(0), at: center("q"), time: 1)
        touches.cancelled(finger(0))
        #expect(recorder.typed.isEmpty)
        #expect(!touches.isTracking)
    }

    @Test func swipeKeySendsArrowsAndEndsWithTheDrag() {
        let row = KeyboardGeometry(
            row: ExtraKeys.standard,
            metrics: KeyboardMetrics(
                keyHeight: 42, keySpacing: 6, rowSpacing: 0, insets: UIEdgeInsets(top: 8, left: 6, bottom: 0, right: 6),
                cornerRadius: 9, labelScale: 1))
        touches.hitTest = { row.hit(at: $0) }
        let swipe = row.caps.first { $0.key.action == .arrows }!.frame
        let start = CGPoint(x: swipe.midX, y: swipe.midY)
        touches.began(finger(0), at: start, time: 1)
        #expect(touches.isSwiping)
        touches.moved(finger(0), to: CGPoint(x: start.x - 40, y: start.y), time: 1.05)
        touches.tick(at: 1.2)
        touches.ended(finger(0), at: CGPoint(x: start.x - 40, y: start.y), time: 1.3)
        #expect(recorder.arrows == [.left, .left])
        #expect(recorder.events.last == .swipeEnded)
        #expect(recorder.typed.isEmpty)
    }

    /// A tap on the swipe key, for those who cannot drag, sends the arrow drawn where it lands; a
    /// tap on the dot in the middle sends nothing.
    @Test func tapOnTheSwipeKeySendsTheArrowItLandsOn() {
        let row = KeyboardGeometry(
            row: ExtraKeys.standard,
            metrics: KeyboardMetrics(
                keyHeight: 42, keySpacing: 6, rowSpacing: 0, insets: UIEdgeInsets(top: 8, left: 6, bottom: 0, right: 6),
                cornerRadius: 9, labelScale: 1))
        touches.hitTest = { row.hit(at: $0) }
        let swipe = row.caps.first { $0.key.action == .arrows }!.frame
        let taps = [
            CGPoint(x: swipe.midX, y: swipe.minY + 4), CGPoint(x: swipe.minX + 4, y: swipe.midY + 2),
            CGPoint(x: swipe.maxX - 4, y: swipe.midY), CGPoint(x: swipe.midX + 1, y: swipe.maxY - 3),
            CGPoint(x: swipe.midX, y: swipe.midY),
        ]
        for (index, point) in taps.enumerated() {
            touches.began(finger(0), at: point, time: Double(index))
            touches.ended(finger(0), at: CGPoint(x: point.x + 3, y: point.y), time: Double(index) + 0.1)
        }
        #expect(recorder.arrows == [.up, .left, .right, .down])
        #expect(recorder.events.filter { $0 == .swipeEnded }.count == 5)
        #expect(recorder.typed.isEmpty)
        // With VoiceOver, whose touches the key gets straight through, a tap sends nothing.
        touches.tapsSendArrows = { false }
        touches.began(finger(0), at: taps[0], time: 10)
        touches.ended(finger(0), at: taps[0], time: 10.1)
        #expect(recorder.arrows.count == 4)
    }

    /// A modifier held on its own for half a second locks, for those who cannot double-tap
    /// quickly; one held while another key is typed, or only tapped, does not.
    @Test func holdingAModifierOnItsOwnLocksIt() {
        let shift = geometry.caps.first { $0.key.label == "⇧" }!.key
        touches.began(finger(0), at: center("⇧"), time: 1)
        touches.ended(finger(0), at: center("⇧"), time: 1.6)
        #expect(recorder.events.last == .lock(shift, time: 1.6))
        recorder.events.removeAll()
        touches.began(finger(0), at: center("⇧"), time: 2)
        touches.began(finger(1), at: center("a"), time: 2.1)
        touches.ended(finger(1), at: center("a"), time: 2.2)
        touches.ended(finger(0), at: center("⇧"), time: 3)
        touches.began(finger(0), at: center("⇧"), time: 4)
        touches.ended(finger(0), at: center("⇧"), time: 4.1)
        let locks = recorder.events.filter { event in
            if case .lock = event { return true }
            return false
        }
        #expect(locks.isEmpty)
    }
}

/// What the touches report.
@MainActor
final class EventRecorder {
    var events: [KeyTouches.Event] = []

    var presses: [(key: KeyboardKey, text: String?, isRepeat: Bool, time: TimeInterval)] {
        events.compactMap { event in
            guard case .press(let key, let text, let isRepeat, let time) = event else { return nil }
            return (key, text, isRepeat, time)
        }
    }

    /// What the presses typed: a flick's or an alternate's text, or the key's own.
    var typed: [String] {
        presses.compactMap { press in
            if let text = press.text { return text }
            guard case .text(let text) = press.key.action else { return nil }
            return text
        }
    }

    var pressTimes: [TimeInterval] { presses.map(\.time) }

    var arrows: [SwipeKey.Direction] {
        events.compactMap { event in
            guard case .arrow(let direction, _) = event else { return nil }
            return direction
        }
    }
}
