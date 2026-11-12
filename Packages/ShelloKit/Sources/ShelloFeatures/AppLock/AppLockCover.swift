import SwiftUI
import UIKit

extension View {
    /// Puts app lock over the view's scene: the locked screen while `appLock` is locked, and the
    /// privacy cover whenever the scene is not active, so that the app switcher's snapshot shows
    /// neither the screens nor a sheet (README section 13). Apply it to the scene's root view.
    ///
    /// Both draw in a window of their own above the scene's other windows, so that they cover sheets
    /// and alerts too. While Shello is locked, the scene's window is hidden from VoiceOver and loses
    /// the keyboard. `preferredColorScheme`, if set, applies to that window as well.
    public func appLock(_ appLock: AppLock, preferredColorScheme: ColorScheme? = nil) -> some View {
        modifier(AppLockCover(appLock: appLock, preferredColorScheme: preferredColorScheme))
    }
}

private struct AppLockCover: ViewModifier {
    let appLock: AppLock
    let preferredColorScheme: ColorScheme?
    @Environment(\.scenePhase) private var scenePhase
    @State private var window = CoverWindow()

    func body(content: Content) -> some View {
        content
            .background {
                WindowReader { sceneWindow in
                    window.attach(to: sceneWindow, appLock: appLock, preferredColorScheme: preferredColorScheme)
                }
            }
            .onChange(of: cover, initial: true) { _, cover in
                window.show(cover)
            }
    }

    /// The locked screen wins over the privacy cover: it is what the user sees while a prompt for
    /// Face ID makes the scene inactive.
    private var cover: CoverWindow.Cover? {
        if appLock.isLocked {
            .lockedScreen
        } else if scenePhase != .active {
            .privacyCover
        } else {
            nil
        }
    }
}

/// The window above a scene's others that holds the locked screen and the privacy cover. It is
/// hidden while neither shows, so that it takes no touches.
@MainActor
@Observable
private final class CoverWindow {
    enum Cover {
        case lockedScreen
        case privacyCover
    }

    private(set) var cover: Cover?
    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private weak var sceneWindow: UIWindow?
    /// Whether the locked screen has taken the keyboard and VoiceOver from the scene's window, and
    /// not given them back yet.
    @ObservationIgnored private var holdsFocus = false

    /// Creates the window in `sceneWindow`'s scene, once.
    func attach(to sceneWindow: UIWindow, appLock: AppLock, preferredColorScheme: ColorScheme?) {
        guard window == nil, let scene = sceneWindow.windowScene else { return }
        self.sceneWindow = sceneWindow
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = UIUserInterfaceStyle(preferredColorScheme)
        let controller = UIHostingController(rootView: CoverView(window: self, appLock: appLock))
        controller.view.backgroundColor = UIColor(named: "Ground", in: DesignSystem.resourceBundle, compatibleWith: nil)
        window.rootViewController = controller
        window.isHidden = true
        self.window = window
        update()
    }

    func show(_ cover: Cover?) {
        self.cover = cover
        update()
    }

    private func update() {
        guard let window, let sceneWindow else { return }
        let isLocked = cover == .lockedScreen
        sceneWindow.accessibilityElementsHidden = isLocked
        // VoiceOver stays in the locked screen. The privacy cover is only there for the snapshot.
        window.accessibilityViewIsModal = isLocked
        if isLocked {
            // A field under the lock must not keep the keyboard, nor take typing from a hardware one.
            sceneWindow.endEditing(true)
            window.makeKeyAndVisible()
        } else {
            window.isHidden = cover == nil
        }
        if isLocked, !holdsFocus {
            holdsFocus = true
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        } else if cover == nil, holdsFocus {
            // The scene's window gets the keyboard and VoiceOver back once the cover is gone, also
            // when the privacy cover showed in between, while the Face ID prompt closed.
            holdsFocus = false
            sceneWindow.makeKey()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
}

/// The cover window's content.
private struct CoverView: View {
    let window: CoverWindow
    let appLock: AppLock

    var body: some View {
        if window.cover == .lockedScreen {
            LockedScreen(appLock: appLock)
        } else {
            PrivacyCover()
        }
    }
}

extension UIUserInterfaceStyle {
    fileprivate init(_ colorScheme: ColorScheme?) {
        switch colorScheme {
        case .light: self = .light
        case .dark: self = .dark
        default: self = .unspecified
        }
    }
}
