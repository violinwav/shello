import Foundation
import LocalAuthentication
import Synchronization

/// The unlock window (GLOSSARY.md): the time after the user passes app lock during which Shello and
/// its SSH keys work without another prompt (README section 13, STACK section 7.3).
///
/// Passing app lock evaluates one `LAContext`, and everything that needs the user's authentication
/// uses that context until app lock re-engages:
/// - Keychain reads pass it as `kSecUseAuthenticationContext`, as `SecretStore` does.
/// - Secure Enclave signatures pass it as `authenticationContext`, for SSH keys that sign "while
///   Shello is unlocked". Keys that sign on "every use" take a fresh context for each signature.
/// - The SSH agent signs with it once the user has tapped to allow the request. While the window is
///   closed, it opens the window first with `open(reason:)`, which asks for Face ID or Touch ID.
///
/// Use the context only inside `withAuthenticationContext(_:)`, which runs only while the window is
/// open and keeps the context inside. The context shows no interface after the unlock: an operation
/// that it cannot authorise fails with `errSecInteractionNotAllowed` instead of asking again.
///
/// The window closes, and its context is invalidated, when app lock re-engages: on `close()`, or once
/// the app has been in the background for app lock's timeout (`closeAfter(_:)`). The timeout does not
/// wait for the interface, so a connection that resumes before the lock screen shows finds the window
/// closed all the same.
///
/// Use it from any thread or actor. Only `open(reason:)` waits, for the user.
public final class UnlockWindow: Sendable {
    private struct State {
        var context: Context?
        /// When a countdown that `closeAfter(_:)` started ends.
        var deadline: ContinuousClock.Instant?
        /// How often the window closed, so that an unlock that finishes after a closing that came
        /// while it was asking the user is thrown away.
        var closings = 0
    }

    /// The window's `LAContext`, which is not sendable, in a box that can go into the window's lock.
    /// Once in the box, the context is used only inside the lock, so never by two threads at once.
    private final class Context: @unchecked Sendable {
        let context: LAContext

        init(_ context: sending LAContext) {
            self.context = context
        }
    }

    private let state = Mutex(State())
    private let authentication: any Authentication
    private let now: @Sendable () -> ContinuousClock.Instant

    /// A closed window that asks the user through `authentication`. `now` tells the time for the
    /// countdown; the default clock keeps counting while the device sleeps.
    public init(
        authentication: some Authentication = LocalAuthentication(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.authentication = authentication
        self.now = now
    }

    deinit {
        state.withLock { state in
            if let current = state.context { authentication.invalidate(current.context) }
        }
    }

    /// Whether the user can be asked, and with what, or that the device has no passcode.
    public var capability: AuthenticationCapability {
        let context = authentication.makeContext()
        defer { authentication.invalidate(context) }
        return authentication.capability(of: context)
    }

    /// Whether the window is open: the user passed app lock, and it has not re-engaged since.
    public var isOpen: Bool {
        state.withLock { state in
            closeIfDue(&state)
            return state.context != nil
        }
    }

    /// App lock: asks the user to authenticate with Face ID, Touch ID or the passcode, on a new
    /// context, and opens the window with that context. An open window gets the new context.
    /// - Throws: `UnlockError`, `.cancelled` also when the window closed while the user was asked.
    public func open(reason: String) async throws(UnlockError) {
        let closings = state.withLock { $0.closings }
        let context = authentication.makeContext()
        if authentication.capability(of: context) == .passcodeNotSet {
            authentication.invalidate(context)
            throw .passcodeNotSet
        }
        do {
            try await authentication.authenticate(context, reason: reason)
        } catch {
            authentication.invalidate(context)
            throw error
        }
        // From now on the context never asks again.
        context.interactionNotAllowed = true
        let unlocked = Context(context)
        let opened = state.withLock { state in
            guard state.closings == closings else { return false }
            install(unlocked, in: &state)
            return true
        }
        guard opened else {
            authentication.invalidate(unlocked.context)
            throw .cancelled
        }
    }

    /// Opens the window on a context that no one authenticated on, for a device without a passcode,
    /// where app lock cannot ask anyone (`AuthenticationCapability.passcodeNotSet`). Keychain items
    /// without access control read with it; anything that needs the user's presence fails.
    public func openWithoutAuthentication() {
        let context = authentication.makeContext()
        context.interactionNotAllowed = true
        let unauthenticated = Context(context)
        state.withLock { state in install(unauthenticated, in: &state) }
    }

    /// App lock re-engages: the window closes, and its context is invalidated. An unlock that is
    /// still asking the user fails with `UnlockError.cancelled`.
    public func close() {
        state.withLock { state in close(&state) }
    }

    /// The app went to the background: the window closes once `timeout` has passed, unless
    /// `stayOpen()` comes first. With a timeout of zero, it closes at once.
    public func closeAfter(_ timeout: Duration) {
        state.withLock { state in
            guard state.context != nil else { return }
            if timeout <= .zero {
                close(&state)
            } else {
                state.deadline = now() + timeout
            }
        }
    }

    /// The app came back to the foreground: the countdown that `closeAfter(_:)` started stops.
    /// Returns whether the window is still open, which it is not once the timeout has passed.
    public func stayOpen() -> Bool {
        state.withLock { state in
            closeIfDue(&state)
            state.deadline = nil
            return state.context != nil
        }
    }

    /// Runs `body` with the window's context: for a Keychain read or a Secure Enclave signature. The
    /// window stays open while `body` runs, and `close()` waits for it, so `body` must be quick. It
    /// must not keep the context, nor call the window.
    /// - Throws: `UnlockWindowClosed` while the window is closed, or what `body` throws.
    public func withAuthenticationContext<Result: Sendable>(
        _ body: @Sendable (LAContext) throws -> Result
    ) throws -> Result {
        try state.withLock { state in
            closeIfDue(&state)
            guard let current = state.context else { throw UnlockWindowClosed() }
            return try body(current.context)
        }
    }

    private func install(_ context: Context, in state: inout State) {
        if let previous = state.context { authentication.invalidate(previous.context) }
        state.context = context
        state.deadline = nil
    }

    private func close(_ state: inout State) {
        state.closings += 1
        if let current = state.context { authentication.invalidate(current.context) }
        state.context = nil
        state.deadline = nil
    }

    private func closeIfDue(_ state: inout State) {
        if let deadline = state.deadline, now() >= deadline {
            close(&state)
        }
    }
}

/// The unlock window is closed: app lock has engaged, so nothing that needs the user's authentication
/// runs until they unlock Shello again.
public struct UnlockWindowClosed: Error, Equatable, CustomStringConvertible {
    public init() {}

    public var description: String { "Shello is locked. Unlock it, then try again." }
}
