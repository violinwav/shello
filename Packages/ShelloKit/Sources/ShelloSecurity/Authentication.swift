import Foundation
import LocalAuthentication

/// How the unlock window asks the user to prove that they own the device (STACK section 7.3).
/// `LocalAuthentication` asks for Face ID, Touch ID or the device passcode; tests inject a stand-in
/// that answers at once.
public protocol Authentication: Sendable {
    /// A new context that no one has authenticated on yet.
    func makeContext() -> sending LAContext
    /// Whether the user can be asked on `context`, and with what.
    func capability(of context: LAContext) -> AuthenticationCapability
    /// Asks the user to authenticate on `context`. `reason` says why, under Touch ID's prompt and
    /// the passcode's.
    func authenticate(_ context: LAContext, reason: String) async throws(UnlockError)
    /// Ends `context`: whatever holds it can no longer use it, and a prompt on it is cancelled.
    func invalidate(_ context: LAContext)
}

/// What the device asks the user for, first.
public enum Biometry: Sendable, Equatable {
    case faceID
    case touchID
    case opticID
    /// The passcode only.
    case none
}

/// Whether the device can ask the user to prove that they own it.
public enum AuthenticationCapability: Sendable, Equatable {
    /// It can: with `biometry`, and with the passcode when biometry fails or there is none.
    case available(Biometry)
    /// The device has no passcode, so it cannot ask anyone (README section 13).
    case passcodeNotSet
}

/// Why the unlock window did not open.
public enum UnlockError: Error, Equatable, Sendable {
    /// The user, the system or Shello ended the prompt, for example because the app left the
    /// foreground, or app lock re-engaged while the user was being asked.
    case cancelled
    /// The user did not prove that they own the device.
    case failed
    /// The device has no passcode, so app lock cannot ask anyone.
    case passcodeNotSet
    /// LocalAuthentication failed for another reason, with this `LAError.Code`.
    case other(code: Int)

    /// The unlock error for an error that LocalAuthentication reported.
    public init(_ error: any Error) {
        guard let error = error as? LAError else {
            self = .other(code: (error as NSError).code)
            return
        }
        switch error.code {
        case .userCancel, .systemCancel, .appCancel, .userFallback, .notInteractive, .invalidContext:
            self = .cancelled
        case .authenticationFailed, .biometryLockout:
            self = .failed
        case .passcodeNotSet:
            self = .passcodeNotSet
        default:
            self = .other(code: error.code.rawValue)
        }
    }
}

/// LocalAuthentication's device owner authentication: Face ID, Touch ID or Optic ID, with the
/// device passcode as the fallback (`LAPolicy.deviceOwnerAuthentication`).
public struct LocalAuthentication: Authentication {
    public init() {}

    public func makeContext() -> sending LAContext {
        LAContext()
    }

    public func capability(of context: LAContext) -> AuthenticationCapability {
        var error: NSError?
        let canAsk = unsafe context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        if !canAsk, let error, UnlockError(error) == .passcodeNotSet {
            return .passcodeNotSet
        }
        // Any other problem shows when the user is asked.
        return switch context.biometryType {
        case .faceID: .available(.faceID)
        case .touchID: .available(.touchID)
        case .opticID: .available(.opticID)
        default: .available(.none)
        }
    }

    public func authenticate(_ context: LAContext, reason: String) async throws(UnlockError) {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? LAError(.authenticationFailed))
                    }
                }
            }
        } catch {
            throw UnlockError(error)
        }
    }

    public func invalidate(_ context: LAContext) {
        context.invalidate()
    }
}
