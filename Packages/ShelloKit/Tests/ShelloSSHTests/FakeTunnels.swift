import Foundation
import Synchronization

@testable import ShelloSSH

/// A tunnel whose far end is in the test: it takes what is sent at the pace the test sets, keeps it,
/// and sends what the test gives it, at once or as fast as it is read.
final class FakeTunnel: ForwardTunnel {
    private struct State {
        /// Bytes sent that the far end has not taken.
        var unsent = 0
        /// Bytes the far end took, in order.
        var taken: [UInt8] = []
        var finished = false
        var closed = false
        /// What the far end sends next, chunk by chunk.
        var outgoing: [[UInt8]] = []
        var outgoingEnded = false
        /// Bytes the far end can still produce on demand, in chunks of `chunkSize`, when it is a source.
        var produce = 0
        var produced = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// Counts the changes, so that a wait never misses one.
        var version = 0
    }

    private let state = Mutex(State())
    /// How many bytes the far end takes at once, every `pace`; nil takes everything at once.
    private let window: Int?
    private let pace: Duration

    /// A far end that takes `window` bytes every `pace`, or everything at once without a window.
    init(window: Int? = nil, pace: Duration = .milliseconds(1)) {
        self.window = window
        self.pace = pace
    }

    /// Everything the far end took, in order.
    var taken: [UInt8] { state.withLock(\.taken) }
    var isFinished: Bool { state.withLock(\.finished) }
    var isClosed: Bool { state.withLock(\.closed) }
    /// How many bytes the far end produced as a source.
    var produced: Int { state.withLock(\.produced) }

    /// The far end sends `bytes`.
    func far(send bytes: [UInt8]) {
        state.withLock { $0.outgoing.append(bytes) }
        wake()
    }

    /// The far end ends its side.
    func farEnd() {
        state.withLock { $0.outgoingEnded = true }
        wake()
    }

    /// The far end produces `count` bytes of a pattern, as fast as they are read, then ends.
    func produce(_ count: Int) {
        state.withLock { $0.produce = count }
        wake()
    }

    static let chunkSize = 32 * 1024

    func send(_ bytes: [UInt8]) {
        guard let window else {
            state.withLock { $0.taken += bytes }
            return
        }
        let pending = state.withLock { state in
            state.unsent += bytes.count
            state.taken += bytes
            return state.unsent
        }
        if pending == bytes.count {
            Task { await self.takeSlowly(window) }
        }
    }

    private func takeSlowly(_ window: Int) async {
        while state.withLock({ $0.unsent > 0 && !$0.closed }) {
            try? await Task.sleep(for: pace)
            state.withLock { $0.unsent = max(0, $0.unsent - window) }
            wake()
        }
    }

    var unsentByteCount: Int { state.withLock(\.unsent) }

    func drain() async throws {
        while true {
            let (isDrained, isClosed, version) = state.withLock { ($0.unsent == 0, $0.closed, $0.version) }
            if isClosed { throw SSHError.closed }
            if isDrained { return }
            await waitForChange(since: version)
        }
    }

    func finish() {
        state.withLock { $0.finished = true }
        wake()
    }

    func receive() async throws -> [UInt8]? {
        while true {
            var version = 0
            let next: [UInt8]?? = state.withLock { state in
                version = state.version
                if state.closed { return .some(nil) }
                if !state.outgoing.isEmpty { return .some(state.outgoing.removeFirst()) }
                if state.produced < state.produce {
                    let count = min(Self.chunkSize, state.produce - state.produced)
                    let chunk = (0..<count).map { UInt8(truncatingIfNeeded: state.produced + $0) }
                    state.produced += count
                    return .some(chunk)
                }
                if state.outgoingEnded || (state.produce > 0 && state.produced == state.produce) {
                    return .some(nil)
                }
                return nil
            }
            if let next { return next }
            await waitForChange(since: version)
        }
    }

    func close() async {
        state.withLock { $0.closed = true }
        wake()
    }

    /// Returns once something changed since `version`.
    private func waitForChange(since version: Int) async {
        await withCheckedContinuation { continuation in
            let hasChanged = state.withLock { state in
                guard state.version == version else { return true }
                state.waiters.append(continuation)
                return false
            }
            if hasChanged { continuation.resume() }
        }
    }

    private func wake() {
        let waiters = state.withLock { state in
            state.version += 1
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Opens fake tunnels, records where to, and lets a test say how each one goes.
final class FakeTunnelOpener: Sendable {
    private let state = Mutex<(destinations: [String], tunnels: [FakeTunnel], failure: (any Error)?)>(([], [], nil))
    private let makeTunnel: @Sendable () -> FakeTunnel

    init(makeTunnel: @escaping @Sendable () -> FakeTunnel = { FakeTunnel() }) {
        self.makeTunnel = makeTunnel
    }

    /// Where each tunnel was opened to, as `address:port`.
    var destinations: [String] { state.withLock(\.destinations) }
    var tunnels: [FakeTunnel] { state.withLock(\.tunnels) }

    /// The tunnels from now on fail to open with `error`.
    func fail(with error: any Error) {
        state.withLock { $0.failure = error }
    }

    var open: ForwardTunnelOpener {
        { [self] address, port in
            let tunnel = makeTunnel()
            let failure = state.withLock { state in
                state.destinations.append(address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)")
                if state.failure == nil { state.tunnels.append(tunnel) }
                return state.failure
            }
            if let failure { throw failure }
            return tunnel
        }
    }
}
