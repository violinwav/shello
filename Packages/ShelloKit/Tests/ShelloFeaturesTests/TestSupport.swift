import Foundation
import LocalAuthentication
import Observation
import ShelloModel
import ShelloStorage
import Synchronization
import Testing

@testable import ShelloSecurity

/// Swift Testing declares a `Tag` type too.
typealias Tag = ShelloModel.Tag

/// Secrets in a Keychain in memory, behind an unlock window that is open, as it is while the user
/// edits hosts.
nonisolated final class TestSecrets: Sendable {
    let keychain = MemoryKeychain()
    let window = UnlockWindow(authentication: TestAuthentication())
    let store: SecretStore

    init() {
        store = SecretStore(keychain: keychain, unlockWindow: window)
        window.openWithoutAuthentication()
    }

    /// The password stored for `hostID`, as text.
    func password(of hostID: Host.ID) throws -> String? {
        try store.secret(.password(of: hostID)).map { secret in
            secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        }
    }
}

/// SSH keys in memory, behind an unlock window that is open, as it is while the user manages keys.
/// With `secureEnclave`, a stand-in makes the Secure Enclave's kind of key.
nonisolated final class TestKeys: Sendable {
    private let items = MemoryKeyItems()
    let window = UnlockWindow(authentication: TestAuthentication())
    let store: SSHKeyStore

    init(secureEnclave: Bool = true) {
        store = SSHKeyStore(
            items: items, enclave: MemoryEnclave(isAvailable: secureEnclave), unlockWindow: window,
            authentication: TestAuthentication())
        window.openWithoutAuthentication()
    }

    /// Makes a key the way the new key sheet does.
    func make(
        _ comment: String, kind: SSHKey.Kind = .ed25519, signingPolicy: SigningPolicy = .whileUnlocked
    ) async throws -> SSHKey {
        try await store.generate(kind, comment: comment, signingPolicy: signingPolicy)
    }

    /// The key data of `key`, its private key or its Secure Enclave blob, which nothing outside
    /// ShelloSecurity can read: for tests that look for it where it must not be.
    func keyData(of key: SSHKey) -> Data? {
        items.keyData(of: key.id, context: LAContext()).map { secret in secret.withUnsafeBytes { Data($0) } }
    }
}

/// LocalAuthentication's stand-in: every prompt is answered at once, as the test says, and counted.
nonisolated final class TestAuthentication: Authentication {
    private struct State {
        var prompts = 0
        var answer: Result<Void, UnlockError> = .success(())
        var capability = AuthenticationCapability.available(.faceID)
    }

    private let state = Mutex(State())

    /// How often the user was asked to authenticate.
    var promptCount: Int { state.withLock { $0.prompts } }

    /// How the next prompts end.
    func answer(_ answer: Result<Void, UnlockError>) {
        state.withLock { $0.answer = answer }
    }

    func setCapability(_ capability: AuthenticationCapability) {
        state.withLock { $0.capability = capability }
    }

    func makeContext() -> sending LAContext {
        LAContext()
    }

    func capability(of context: LAContext) -> AuthenticationCapability {
        state.withLock { $0.capability }
    }

    func authenticate(_ context: LAContext, reason: String) async throws(UnlockError) {
        let answer = state.withLock { state in
            state.prompts += 1
            return state.answer
        }
        try answer.get()
    }

    func invalidate(_ context: LAContext) {}
}

/// A clock that moves only when a test moves it.
nonisolated final class TestTime: Sendable {
    private let current = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { current.withLock { $0 } }

    func advance(by duration: Duration) {
        current.withLock { $0 += duration }
    }
}

/// Settings of their own, deleted when the test ends.
nonisolated final class TestDefaults: @unchecked Sendable {
    private let suite = "ShelloFeaturesTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }
}

/// A real database in its own temporary directory, deleted when the test ends.
nonisolated final class TestDatabase: Sendable {
    let root: URL
    let repository: HostRepository
    let exports: ExportRepository

    init() throws {
        root = URL.temporaryDirectory.appending(
            path: "ShelloFeaturesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let database = try AppDatabase(directory: root)
        repository = HostRepository(database)
        exports = ExportRepository(database)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Waits until `condition` holds, checking it again after every change to the observable state it
/// reads. Stops waiting when the task is cancelled, for example by the suite's time limit, so that
/// the test's expectations then report what is wrong.
func waitUntil(_ condition: @escaping () -> Bool) async {
    while !condition(), !Task.isCancelled {
        let wakeUp = WakeUp()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                wakeUp.install(continuation)
                // `onChange` runs once, before the first change to anything `condition` read is
                // applied. The waiting task resumes on the main actor, after that change.
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    wakeUp.fire()
                }
            }
        } onCancel: {
            wakeUp.fire()
        }
    }
}

/// Resumes a continuation once, whichever comes first: a change or a cancellation, even one that
/// comes before the continuation is installed.
private nonisolated final class WakeUp: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var fired = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let firedAlready = state.withLock { state in
            if !state.fired { state.continuation = continuation }
            return state.fired
        }
        if firedAlready { continuation.resume() }
    }

    func fire() {
        let continuation = state.withLock { state in
            state.fired = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}
