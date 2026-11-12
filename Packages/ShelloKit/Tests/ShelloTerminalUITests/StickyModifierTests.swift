import Testing
import UIKit

@testable import ShelloTerminalUI

/// Sticky Control and Alt (README section 6): one tap arms, a double tap locks, and the state shows.
@Suite struct StickyModifierTests {
    @Test func oneTapArmsForTheNextKey() {
        var modifier = StickyModifier()
        modifier.tap(at: 10)
        #expect(modifier.state == .armed)
        modifier.use()
        #expect(modifier.state == .off)
    }

    @Test func doubleTapLocksUntilTappedAgain() {
        var modifier = StickyModifier()
        modifier.tap(at: 10)
        modifier.tap(at: 10.2)
        #expect(modifier.state == .locked)
        modifier.use()
        modifier.use()
        #expect(modifier.state == .locked)
        modifier.tap(at: 20)
        #expect(modifier.state == .off)
    }

    /// A second tap after the double tap's time lets an armed modifier go.
    @Test func slowSecondTapTurnsItOff() {
        var modifier = StickyModifier()
        modifier.tap(at: 10)
        modifier.tap(at: 11)
        #expect(modifier.state == .off)
        modifier.tap(at: 12)
        #expect(modifier.state == .armed)
    }

    /// VoiceOver's and Switch Control's actions lock and unlock at once.
    @Test func lockAndUnlockAtOnce() {
        var modifier = StickyModifier()
        modifier.set(locked: true)
        #expect(modifier.state == .locked)
        modifier.use()
        #expect(modifier.state == .locked)
        modifier.set(locked: false)
        #expect(modifier.state == .off)
        modifier.tap(at: 30)
        #expect(modifier.state == .armed)
    }

    @Test func badgeSaysWhatIsOn() {
        #expect(ArmedModifiers().summary == nil)
        #expect(ArmedModifiers(control: .armed).summary == "CTRL armed · next key sends ⌃")
        #expect(ArmedModifiers(control: .locked).summary == "CTRL locked")
        #expect(ArmedModifiers(alt: .armed).summary == "ALT armed · next key sends Esc first")
        #expect(ArmedModifiers(control: .locked, alt: .armed).summary == "CTRL locked · ALT armed")
    }
}

/// The swipe key (README section 6): arrows in the direction of the drag, repeating faster the
/// further the finger is from where it started, and faster still at a higher speed setting.
@Suite struct SwipeKeyTests {
    @Test func directionFollowsTheLongerAxis() {
        #expect(SwipeKey.direction(of: CGVector(dx: 5, dy: 3)) == nil)
        #expect(SwipeKey.direction(of: CGVector(dx: 20, dy: 3)) == .right)
        #expect(SwipeKey.direction(of: CGVector(dx: -20, dy: 8)) == .left)
        #expect(SwipeKey.direction(of: CGVector(dx: 2, dy: -20)) == .up)
        #expect(SwipeKey.direction(of: CGVector(dx: -4, dy: 30)) == .down)
        // Along the diagonal, the current direction stays.
        #expect(SwipeKey.direction(of: CGVector(dx: 20, dy: 22), current: .right) == .right)
        #expect(SwipeKey.direction(of: CGVector(dx: 22, dy: 20), current: .down) == .down)
        #expect(SwipeKey.direction(of: CGVector(dx: 20, dy: 40), current: .right) == .down)
    }

    @Test func rateGrowsWithDistanceAndSpeed() {
        let normal = SwipeKey(speed: 1)
        #expect(normal.rate(atDistance: 13) < normal.rate(atDistance: 40))
        #expect(normal.rate(atDistance: 40) < normal.rate(atDistance: 100))
        let double = SwipeKey(speed: 2)
        #expect(abs(double.rate(atDistance: 40) - 2 * normal.rate(atDistance: 40)) < 0.001)
        #expect(SwipeKey(speed: 3).rate(atDistance: 1000) == SwipeKey.maximumRate)
    }

    /// Drags the swipe key `distance` points right at time 0, holds it there for `seconds`, and
    /// counts the arrows, ticking every 5 ms as the display would.
    private func arrows(distance: CGFloat, seconds: Double, speed: Double = 1) -> [SwipeKey.Direction] {
        var swipe = SwipeKey(speed: speed)
        swipe.began(at: CGPoint(x: 100, y: 20))
        var sent = [swipe.moved(to: CGPoint(x: 100 + distance, y: 21), at: 0)].compactMap(\.self)
        for tick in stride(from: 0.005, through: seconds, by: 0.005) {
            if let arrow = swipe.tick(at: tick) {
                sent.append(arrow)
            }
        }
        return sent
    }

    @Test func repeatsFasterFurtherOut() {
        let near = arrows(distance: 20, seconds: 1)
        let far = arrows(distance: 80, seconds: 1)
        #expect(near.allSatisfy { $0 == .right })
        // One at once, then the rate: 4 + 0.25 × 8 = 6 a second near, 21 far.
        #expect((6...7).contains(near.count))
        #expect((21...22).contains(far.count))
        let faster = arrows(distance: 80, seconds: 1, speed: 2)
        #expect((41...43).contains(faster.count))
    }

    @Test func turningSendsTheNewDirectionAtOnceAndTheDeadZoneStops() {
        var swipe = SwipeKey()
        swipe.began(at: CGPoint(x: 100, y: 20))
        #expect(swipe.moved(to: CGPoint(x: 105, y: 20), at: 0) == nil)
        #expect(swipe.moved(to: CGPoint(x: 130, y: 20), at: 0.1) == .right)
        #expect(swipe.moved(to: CGPoint(x: 135, y: 22), at: 0.15) == nil)
        #expect(swipe.moved(to: CGPoint(x: 100, y: 60), at: 0.2) == .down)
        #expect(swipe.moved(to: CGPoint(x: 102, y: 25), at: 0.3) == nil)
        #expect(swipe.deadline == nil)
        #expect(swipe.tick(at: 5) == nil)
    }

    /// A stalled main thread gets one arrow when it comes back, not every arrow it missed.
    @Test func stallSendsOneArrowNotABurst() {
        var swipe = SwipeKey()
        swipe.began(at: CGPoint(x: 100, y: 20))
        _ = swipe.moved(to: CGPoint(x: 160, y: 20), at: 0)
        #expect(swipe.tick(at: 2) == .right)
        #expect(swipe.tick(at: 2.001) == nil)
    }

    /// A tap sends the arrow drawn on the side of the key it lands on, and nothing on the dot in
    /// the middle.
    @Test func tapSendsTheArrowOnItsSide() {
        let key = CGRect(x: 100, y: 8, width: 42, height: 42)
        #expect(SwipeKey.direction(ofTapAt: CGPoint(x: 121, y: 10), in: key) == .up)
        #expect(SwipeKey.direction(ofTapAt: CGPoint(x: 121, y: 48), in: key) == .down)
        #expect(SwipeKey.direction(ofTapAt: CGPoint(x: 102, y: 30), in: key) == .left)
        #expect(SwipeKey.direction(ofTapAt: CGPoint(x: 140, y: 27), in: key) == .right)
        #expect(SwipeKey.direction(ofTapAt: CGPoint(x: 122, y: 30), in: key) == nil)
    }

    /// A drag that sent an arrow is no tap, even back in the dead zone.
    @Test func dragThatSentIsNoTap() {
        var swipe = SwipeKey()
        swipe.began(at: CGPoint(x: 100, y: 20))
        #expect(!swipe.hasSent)
        _ = swipe.moved(to: CGPoint(x: 120, y: 20), at: 0)
        _ = swipe.moved(to: CGPoint(x: 102, y: 20), at: 0.1)
        #expect(swipe.hasSent)
    }
}
