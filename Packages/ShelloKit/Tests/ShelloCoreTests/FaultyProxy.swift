import Foundation
import LocalAuthentication
import Network
import ShelloSecurity
import Synchronization

/// A TCP proxy on this device's loopback between Shello and the test server, which a test breaks as
/// a network breaks: the fault-injecting transport that the tabs' reconnecting is tested over,
/// instead of Toxiproxy (STACK section 8), which would be one more tool to install.
/// - `cut()` resets every connection through it and refuses new ones, as a network that dropped.
/// - `stall()` passes nothing on any more, in either direction, as a network that went silent,
///   such as one whose router lost the connection: only the keepalive finds it.
/// - `restore()` passes new connections on again.
final class FaultyProxy: Sendable {
    /// The port the proxy listens on, on 127.0.0.1.
    let port: UInt16
    private let listener: NWListener
    private let targetPort: UInt16
    private let queue: DispatchQueue
    private let state = Mutex(State())

    private struct State {
        var mode = Mode.passing
        var connections: [NWConnection] = []
    }

    private enum Mode {
        case passing
        case cut
        case stalled
    }

    /// A proxy to the server on `targetPort` of 127.0.0.1, listening once this returns.
    init(to targetPort: UInt16) async throws {
        let queue = DispatchQueue(label: "ch.shello.tests.proxy")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        self.targetPort = targetPort
        self.queue = queue
        port = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.isFirst() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.isFirst() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
    }

    deinit {
        listener.cancel()
        for connection in state.withLock({ $0.connections }) {
            connection.forceCancel()
        }
    }

    /// Resets every connection through the proxy, and refuses new ones until `restore()`.
    func cut() {
        let connections = state.withLock { state in
            state.mode = .cut
            defer { state.connections = [] }
            return state.connections
        }
        for connection in connections {
            connection.forceCancel()
        }
    }

    /// Passes nothing on any more, in either direction, until `restore()`; the connections stay open.
    func stall() {
        state.withLock { $0.mode = .stalled }
    }

    /// Passes the connections made from now on.
    func restore() {
        state.withLock { $0.mode = .passing }
    }

    private func accept(_ inbound: NWConnection) {
        let mode = state.withLock(\.mode)
        guard mode != .cut else {
            inbound.forceCancel()
            return
        }
        let outbound = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: targetPort)!, using: .tcp)
        state.withLock { $0.connections += [inbound, outbound] }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pipe(from: inbound, to: outbound)
        pipe(from: outbound, to: inbound)
    }

    /// Passes what `source` receives on to `destination`, while the proxy passes, then its end.
    private func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.state.withLock({ $0.mode }) == .passing else { return }
            let next: @Sendable (NWError?) -> Void = { [weak self] sendError in
                if isComplete || error != nil || sendError != nil {
                    destination.send(
                        content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                } else {
                    self?.pipe(from: source, to: destination)
                }
            }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed(next))
            } else {
                next(nil)
            }
        }
    }
}

/// LocalAuthentication's stand-in whose prompts stay up, as Face ID's does while the user looks
/// away, until their context is invalidated: then they end as cancelled, as LocalAuthentication's do.
final class PendingAuthentication: Authentication {
    private struct State {
        var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
        var invalidated: Set<ObjectIdentifier> = []
    }

    private let state = Mutex(State())

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
}
