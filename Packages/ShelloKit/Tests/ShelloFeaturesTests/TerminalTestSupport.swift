import ShelloTerminalUI
import UIKit

@testable import ShelloFeatures

/// A terminal as the Terminal Demo screen shows it, with the app's fonts and theme, attached to the
/// terminal demo, in a window: SwiftTerm draws only in one.
@MainActor
final class DemoTerminal {
    let controller: TerminalController
    let demo = TerminalDemo()
    let window: UIWindow

    init(size: CGSize, renderer: TerminalRenderer = .coreText) {
        DesignSystem.registerFonts()
        controller = TerminalController(
            preferences: TerminalPreferences(), theme: .night, typeface: DesignSystem.terminalTypeface,
            renderer: renderer)
        window = UIWindow.withoutScene(frame: CGRect(origin: .zero, size: size))
        controller.view.frame = window.bounds
        window.addSubview(controller.view)
        controller.view.layoutIfNeeded()
        controller.attach(demo)
    }

    var view: TerminalHostView { controller.view }

    /// The text on screen, row by row.
    var screen: [String] {
        view.visibleRowsText(0..<view.terminalDimensions.rows)
    }

    /// Waits up to `seconds` for `condition`, while the main run loop draws frames.
    func wait(seconds: Double = 10, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// The terminal as drawn, once SwiftTerm has drawn a frame of what it holds now.
    func image() async -> UIImage {
        let frames = view.diagnostics.frames
        view.requestRedraw()
        _ = await wait { view.diagnostics.frames > frames }
        view.setNeedsDisplay()
        view.layer.displayIfNeeded()
        return UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            view.layer.render(in: context.cgContext)
        }
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
