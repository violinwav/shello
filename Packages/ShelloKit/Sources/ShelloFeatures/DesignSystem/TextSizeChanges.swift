import UIKit

extension DesignSystem {
    /// Lays out every window of the app as soon as the text size changes, so that the new size is
    /// drawn and read back before anything else runs on the main thread. Call it once at launch;
    /// later calls do nothing.
    ///
    /// Without it, UIKit and SwiftUI apply a new size in their next layout pass, which waits while
    /// the main thread has other work queued. The accessibility audit's Dynamic Type check sets one
    /// size after another and reads the screen after each. On a slow CI runner its reads kept the
    /// main thread busy, a size was never drawn, and the audit reported text that does scale as
    /// "partially unsupported" (STACK section 7.14).
    public static func applyTextSizeChangesAtOnce() {
        _ = textSizeObserver
    }

    private static let textSizeObserver = NotificationCenter.default.addObserver(
        forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: nil
    ) { _ in
        // UIKit posts it on the main thread, and with no queue the block runs there at once.
        MainActor.assumeIsolated {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows {
                    window.layoutIfNeeded()
                }
            }
        }
    }
}
