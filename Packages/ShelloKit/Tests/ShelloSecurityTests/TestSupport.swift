import CryptoKit
import Foundation
import LocalAuthentication
import Synchronization

@testable import ShelloSecurity

/// LocalAuthentication's stand-in: every prompt is answered at once, as the test says, and counted.
/// The contexts it hands out are never freed, so that their identifiers stay unique.
final class TestAuthentication: Authentication {
    private struct State {
        var prompts: [ObjectIdentifier] = []
        var reasons: [String] = []
        var invalidated: Set<ObjectIdentifier> = []
        var answer: Result<Void, UnlockError> = .success(())
        var capability = AuthenticationCapability.available(.faceID)
    }

    private let state = Mutex(State())

    /// How the next prompts end.
    func answer(_ answer: Result<Void, UnlockError>) {
        state.withLock { $0.answer = answer }
    }

    func setCapability(_ capability: AuthenticationCapability) {
        state.withLock { $0.capability = capability }
    }

    /// How often the user was asked to authenticate.
    var promptCount: Int { state.withLock { $0.prompts.count } }

    /// The contexts the user was asked on, in order.
    var promptedContexts: [ObjectIdentifier] { state.withLock { $0.prompts } }

    var reasons: [String] { state.withLock { $0.reasons } }

    func isInvalidated(_ context: ObjectIdentifier) -> Bool {
        state.withLock { $0.invalidated.contains(context) }
    }

    func makeContext() -> sending LAContext {
        let context = LAContext()
        // A freed context's address, and so its identifier, could come back for the next one.
        _ = unsafe Unmanaged.passRetained(context)
        return context
    }

    func capability(of context: LAContext) -> AuthenticationCapability {
        state.withLock { $0.capability }
    }

    func authenticate(_ context: LAContext, reason: String) async throws(UnlockError) {
        let id = ObjectIdentifier(context)
        let answer = state.withLock { state in
            state.prompts.append(id)
            state.reasons.append(reason)
            return state.answer
        }
        try answer.get()
    }

    func invalidate(_ context: LAContext) {
        let id = ObjectIdentifier(context)
        state.withLock { _ = $0.invalidated.insert(id) }
    }
}

/// LocalAuthentication's stand-in whose prompts stay up, as Face ID's does while the user looks
/// away, until their context is invalidated: then they end as cancelled, as LocalAuthentication's
/// do.
final class PendingAuthentication: Authentication {
    private struct State {
        var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
        var invalidated: Set<ObjectIdentifier> = []
        var prompts = 0
    }

    private let state = Mutex(State())

    /// How often the user was asked.
    var promptCount: Int { state.withLock { $0.prompts } }

    /// The prompts still up.
    var openPromptCount: Int { state.withLock { $0.waiting.count } }

    func makeContext() -> sending LAContext {
        let context = LAContext()
        // A freed context's address, and so its identifier, could come back for the next one.
        _ = unsafe Unmanaged.passRetained(context)
        return context
    }

    func capability(of context: LAContext) -> AuthenticationCapability {
        .available(.faceID)
    }

    func authenticate(_ context: LAContext, reason: String) async throws(UnlockError) {
        let id = ObjectIdentifier(context)
        await withCheckedContinuation { continuation in
            let isInvalidated = state.withLock { state in
                state.prompts += 1
                guard !state.invalidated.contains(id) else { return true }
                state.waiting[id] = continuation
                return false
            }
            if isInvalidated {
                continuation.resume()
            }
        }
        throw .cancelled
    }

    func invalidate(_ context: LAContext) {
        let id = ObjectIdentifier(context)
        let waiting = state.withLock { state in
            state.invalidated.insert(id)
            return state.waiting.removeValue(forKey: id)
        }
        waiting?.resume()
    }

    /// Returns once a prompt is up.
    func waitForPrompt() async {
        while openPromptCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A `MemoryKeychain` that notes the context of every read, and whether that context could still
/// have asked the user anything.
final class RecordingKeychain: Keychain {
    struct Read: Equatable {
        let context: ObjectIdentifier
        let interactionNotAllowed: Bool
    }

    private let items = MemoryKeychain()
    private let recorded = Mutex<[Read]>([])

    var reads: [Read] { recorded.withLock { $0 } }

    func store(_ secret: Secret, as id: SecretID) {
        items.store(secret, as: id)
    }

    func secret(_ id: SecretID, context: LAContext) -> Secret? {
        record(context)
        return items.secret(id, context: context)
    }

    func contains(_ id: SecretID, context: LAContext) -> Bool {
        record(context)
        return items.contains(id, context: context)
    }

    func remove(_ id: SecretID) {
        items.remove(id)
    }

    private func record(_ context: LAContext) {
        let read = Read(context: ObjectIdentifier(context), interactionNotAllowed: context.interactionNotAllowed)
        recorded.withLock { $0.append(read) }
    }
}

/// `MemoryKeyItems` that notes the context of every read of key data, as `RecordingKeychain` does.
final class RecordingKeyItems: KeyItems {
    let items = MemoryKeyItems()
    private let recorded = Mutex<[RecordingKeychain.Read]>([])

    var reads: [RecordingKeychain.Read] { recorded.withLock { $0 } }

    func add(_ record: KeyRecord, keyData: Secret, requiresUserPresence: Bool) throws {
        try items.add(record, keyData: keyData, requiresUserPresence: requiresUserPresence)
    }

    func records() -> [KeyRecord] {
        items.records()
    }

    func keyData(of id: UUID, context: LAContext) -> Secret? {
        let read = RecordingKeychain.Read(
            context: ObjectIdentifier(context), interactionNotAllowed: context.interactionNotAllowed)
        recorded.withLock { $0.append(read) }
        return items.keyData(of: id, context: context)
    }

    func remove(_ id: UUID) {
        items.remove(id)
    }
}

/// `MemoryEnclave` that notes the context of every signature.
final class RecordingEnclave: Enclave {
    let enclave: MemoryEnclave
    private let recorded = Mutex<[RecordingKeychain.Read]>([])

    init(isAvailable: Bool = true) {
        enclave = MemoryEnclave(isAvailable: isAvailable)
    }

    /// The context of each signature, in order.
    var signatures: [RecordingKeychain.Read] { recorded.withLock { $0 } }

    var isAvailable: Bool { enclave.isAvailable }

    func makeKey() throws -> (blob: Data, publicKey: P256.Signing.PublicKey) {
        try enclave.makeKey()
    }

    func signature(for data: Data, blob: Data, context: LAContext) throws -> P256.Signing.ECDSASignature {
        let signature = RecordingKeychain.Read(
            context: ObjectIdentifier(context), interactionNotAllowed: context.interactionNotAllowed)
        recorded.withLock { $0.append(signature) }
        return try enclave.signature(for: data, blob: blob, context: context)
    }
}

/// A clock that moves only when a test moves it.
final class TestTime: Sendable {
    private let current = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { current.withLock { $0 } }

    func advance(by duration: Duration) {
        current.withLock { $0 += duration }
    }
}
