import SwiftUI
import UIKit

/// Tells its closure which window the view is in, once it is in one: for what SwiftUI does not say
/// of the window, such as its scene.
struct WindowReader: UIViewRepresentable {
    let onWindow: (UIWindow) -> Void

    func makeUIView(context: Context) -> WindowReportingView {
        WindowReportingView(onWindow: onWindow)
    }

    func updateUIView(_ view: WindowReportingView, context: Context) {
        view.onWindow = onWindow
    }
}

final class WindowReportingView: UIView {
    var onWindow: (UIWindow) -> Void

    init(onWindow: @escaping (UIWindow) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { onWindow(window) }
    }
}
