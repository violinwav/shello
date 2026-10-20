import Foundation
import Observation
import ShelloModel
import ShelloStorage
import Synchronization
import Testing

/// Swift Testing declares a `Tag` type too.
typealias Tag = ShelloModel.Tag

/// A real database in its own temporary directory, deleted when the test ends.
nonisolated final class TestDatabase: Sendable {
    let root: URL
    let repository: HostRepository

    init() throws {
        root = URL.temporaryDirectory.appending(
            path: "ShelloFeaturesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        repository = HostRepository(try AppDatabase(directory: root))
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
