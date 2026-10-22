import ShelloModel
import Synchronization
import UIKit

@testable import ShelloTerminalUI

/// A byte stream for tests: the test writes its output, and it records what the terminal sends.
nonisolated final class RecordingStream: TerminalByteStream {
    let output: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let recorded = Mutex(Recorded())

    private struct Recorded {
        var sent: [UInt8] = []
        var sizes: [TerminalSize] = []
    }

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    /// Output from the remote end.
    func write(_ text: String) {
        continuation.yield(Array(text.utf8))
    }

    func finish(throwing error: (any Error)? = nil) {
        continuation.finish(throwing: error)
    }

    var sent: [UInt8] { recorded.withLock { $0.sent } }
    var sentText: String { String(decoding: sent, as: UTF8.self) }
    var sizes: [TerminalSize] { recorded.withLock { $0.sizes } }

    func send(_ bytes: [UInt8]) {
        recorded.withLock { $0.sent += bytes }
    }

    func resize(to size: TerminalSize) {
        recorded.withLock { $0.sizes.append(size) }
    }
}

/// What a controller tells the user, recorded instead of spoken or felt, and what it copies.
@MainActor
final class RecordedFeedback {
    var isVoiceOverRunning = false
    var announcements: [String] = []
    var priorities: [AnnouncementPriority] = []
    var taps = 0
    var copied: [String] = []

    var feedback: TerminalFeedback {
        TerminalFeedback(
            isVoiceOverRunning: { [unowned self] in self.isVoiceOverRunning },
            announce: { [unowned self] message, priority in
                self.announcements.append(message)
                self.priorities.append(priority)
            },
            tap: { [unowned self] in self.taps += 1 },
            copy: { [unowned self] in self.copied.append($0) })
    }
}

extension UIWindow {
    /// A window for a view under test. SwiftTerm draws, and applies a new size, only in a window,
    /// but it does not need the window to show. The package's tests run without an app, so there
    /// is no scene for `init(windowScene:)`. The window comes from `+[UIWindow new]`, which is
    /// `init(frame:)`, deprecated since iOS 26: called by name, it does not fail the build, which
    /// treats warnings as errors.
    static func withoutScene(frame: CGRect) -> UIWindow {
        let made = (UIWindow.self as AnyObject).perform(NSSelectorFromString("new"))
        let window = made!.takeRetainedValue() as! UIWindow
        window.frame = frame
        return window
    }
}

/// A controller whose view is in a window, as on screen.
@MainActor
final class TerminalFixture {
    let controller: TerminalController
    let window: UIWindow
    let recorded = RecordedFeedback()

    init(
        preferences: TerminalPreferences = TerminalPreferences(), size: CGSize = CGSize(width: 390, height: 400),
        voiceOver: Bool = false
    ) {
        recorded.isVoiceOverRunning = voiceOver
        controller = TerminalController(
            preferences: preferences, theme: .night, typeface: .system, renderer: .coreText,
            feedback: recorded.feedback)
        window = UIWindow.withoutScene(frame: CGRect(origin: .zero, size: size))
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        controller.view.layoutIfNeeded()
    }

    var view: TerminalHostView { controller.view }

    /// Waits until the grid fits the view: SwiftTerm applies a new size with its next frame.
    func settle() async -> Bool {
        await wait {
            let columns = Int(view.bounds.width / view.cellSize.width)
            return controller.size.columns == columns && view.terminalDimensions.cols == columns
        }
    }

    /// The text on screen, row by row, without trailing blanks.
    var screen: [String] {
        view.visibleRowsText(0..<view.terminalDimensions.rows).map {
            String($0.reversed().drop(while: { $0 == " " }).reversed())
        }
    }

    /// Waits up to five seconds for `condition`, while the main run loop draws frames.
    func wait(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Feeds `text` as output from the remote end, as the pump does.
    func feed(_ text: String) {
        view.feed(text: text)
    }

    /// The centre of the cell at `column` and `row` on screen, counted from 0.
    func point(column: Int, row: Int) -> CGPoint {
        let cell = view.cellSize
        return CGPoint(
            x: (CGFloat(column) + 0.5) * cell.width,
            y: view.contentOffset.y + (CGFloat(row) + 0.5) * cell.height)
    }
}
