import Foundation
import Observation
import ShelloSecurity

/// App lock (README section 13): Face ID, Touch ID or the passcode when Shello opens, and when it
/// comes back after app lock's timeout in the background. Unlocking opens the unlock window, which
/// the Keychain reads and the SSH keys use; locking closes it.
///
/// The composition root tells it when the app becomes active and when it goes to the background;
/// `appLock(_:preferredColorScheme:)` covers the scene's screens while it is locked. A device without
/// a passcode cannot ask anyone, so app lock lets the user in there and says so in Settings.
@MainActor
@Observable
public final class AppLock {
    /// Whether Shello is locked: its screens are covered and hidden from VoiceOver, and nothing that
    /// needs the unlock window runs.
    public private(set) var isLocked: Bool
    /// Whether the user is being asked to authenticate.
    public private(set) var isUnlocking = false
    /// Why the last unlock failed, for the locked screen. Nil once the user cancelled.
    public private(set) var problem: String?
    /// How long Shello may stay in the background before app lock re-engages. A setting of this
    /// device, which the export leaves out.
    public var timeout: AppLockTimeout {
        didSet { defaults.set(timeout.rawValue, forKey: Self.timeoutKey) }
    }

    /// What the device asks for, as of the last check.
    private(set) var capability: AuthenticationCapability

    private let window: UnlockWindow
    private let defaults: UserDefaults
    private let isEnabled: Bool
    /// Whether the next time the app becomes active asks the user: at launch, and after time in the
    /// background. Not after the prompt itself closes, which makes the app active again too.
    private var asksWhenActive = true

    static let timeoutKey = "appLockTimeout"

    /// App lock on `window`, with its timeout stored in `defaults`. Debug builds pass `isEnabled:
    /// false` for UI tests that are not about app lock; app lock then never asks.
    public init(window: UnlockWindow, defaults: UserDefaults = .standard, isEnabled: Bool = true) {
        self.window = window
        self.defaults = defaults
        self.isEnabled = isEnabled
        timeout = (defaults.object(forKey: Self.timeoutKey) as? Int).flatMap(AppLockTimeout.init) ?? .standard
        let capability = window.capability
        self.capability = capability
        // Decided before the first screen draws, so that a device that cannot ask shows no lock.
        isLocked = isEnabled && capability != .passcodeNotSet
        if !isLocked {
            window.openWithoutAuthentication()
        }
    }

    /// Whether app lock asks the user at all: not on a device without a passcode.
    public var canAsk: Bool { capability != .passcodeNotSet }

    /// What the device asks for first, which the locked screen names.
    public var biometry: Biometry {
        if case .available(let biometry) = capability { biometry } else { .none }
    }

    /// The app became active, at launch or on its way back from the background or a prompt. App lock
    /// engages if the app was away for the timeout, and asks the user if it is locked and was away.
    public func appDidBecomeActive() {
        capability = window.capability
        if !isLocked, !window.stayOpen() {
            lock()
        }
        guard isLocked, asksWhenActive else { return }
        asksWhenActive = false
        Task { await unlock() }
    }

    /// The app went to the background: the unlock window closes once the timeout has passed, at
    /// once for "Immediately", so that the locked screen is already up when the user comes back.
    public func appDidEnterBackground() {
        asksWhenActive = true
        guard !isLocked else { return }
        window.closeAfter(timeout.duration)
        if !window.isOpen {
            lock()
        }
    }

    /// Asks the user to authenticate, and unlocks Shello if they do.
    public func unlock() async {
        guard isLocked, !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        problem = nil
        do {
            try await window.open(reason: "Unlock Shello to see your hosts.")
            isLocked = false
        } catch {
            switch error {
            case .passcodeNotSet:
                // The passcode was turned off meanwhile: nobody can be asked any more.
                capability = .passcodeNotSet
                window.openWithoutAuthentication()
                isLocked = false
            case .cancelled:
                // The user or the system ended the prompt; the locked screen offers to try again.
                break
            case .failed:
                problem = "Shello couldn’t confirm that it’s you. Try again."
            case .other(let code):
                problem = "Shello couldn’t ask you to unlock (error \(code)). Try again."
            }
        }
    }

    /// App lock re-engages and closes the unlock window. Without anyone to ask, the window opens again
    /// at once without authentication.
    private func lock() {
        window.close()
        problem = nil
        if isEnabled, canAsk {
            isLocked = true
        } else {
            window.openWithoutAuthentication()
        }
    }
}

extension AppLockTimeout {
    /// The timeout as Settings offers it.
    var displayName: String {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 Minute"
        case .fiveMinutes: "After 5 Minutes"
        case .fifteenMinutes: "After 15 Minutes"
        }
    }
}

extension Biometry {
    /// What the device asks for, as the user knows it.
    var displayName: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .none: "Passcode"
        }
    }

    /// What the device asks for, inside a sentence: "Face ID", or "your passcode".
    var inSentence: String {
        self == .none ? "your passcode" : displayName
    }
}
