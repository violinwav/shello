import Foundation
import Observation
import ShelloModel
import ShelloSSH
import os

/// A tab's port forwards (README section 4), as its host had them when the tab last connected, and
/// how each one stands, for the Connection sheet.
///
/// Other apps on the device can reach a loopback listener too, so the forwards listen only while
/// they are needed (STACK section 7.1): from the moment the tab's connection is signed in and its
/// session started, while Shello is in the foreground, until the connection drops or closes, or
/// Shello leaves the foreground. A reconnect, or Shello's return to the foreground with the
/// connection still open, listens again. A forward whose port another tab or app has fails on its
/// own, and says so; the others listen.
@MainActor
@Observable
public final class TabForwards {
    /// The forwards, in the host's order, each with how it stands.
    public private(set) var forwards: [Forward] = []

    /// One of the tab's forwards.
    public struct Forward: Identifiable, Equatable, Sendable {
        public let forward: PortForward
        public var state: ForwardState

        public var id: PortForward.ID { forward.id }
    }

    @ObservationIgnored private var listeners: [PortForward.ID: PortForwardListener] = [:]
    /// The listeners stopped whose ports the system has not let go of yet: a new listener on the same
    /// port waits for them, so that a reconnect does not find its own port in use.
    @ObservationIgnored private var stopping: [PortForwardListener] = []
    /// Counts the starts and stops, so that what a listener reports after a stop changes nothing.
    @ObservationIgnored private var generation = 0

    init() {}

    isolated deinit {
        for listener in listeners.values {
            listener.stop()
        }
    }

    /// Whether any forward is listening or starting to.
    public var isActive: Bool {
        forwards.contains { forward in
            switch forward.state {
            case .starting, .listening: true
            case .off, .waiting, .failed: false
            }
        }
    }

    /// Takes the host's forwards, as they are when the tab connects: none listens yet. Those
    /// switched off stay off.
    func set(_ portForwards: [PortForward]) {
        stop()
        forwards = portForwards.map { Forward(forward: $0, state: $0.isEnabled ? .waiting : .off) }
    }

    /// Listens for each forward that is on, and carries each connection it accepts through a tunnel
    /// from `open`. Each forward that cannot listen fails alone.
    func start(opening open: @escaping ForwardTunnelOpener) {
        stop()
        generation += 1
        let generation = generation
        for index in forwards.indices where forwards[index].state != .off {
            let forward = forwards[index].forward
            let target: PortForwardListener.Target =
                switch forward.kind {
                case .local(let destination): .destination(address: destination.address, port: destination.port)
                case .dynamic: .socks
                }
            let id = forward.id
            let listener = PortForwardListener(
                port: forward.localPort, target: target, open: open,
                report: { [weak self] activity in
                    Task { @MainActor in self?.listener(id, reported: activity, generation: generation) }
                })
            listeners[id] = listener
            forwards[index].state = .starting
            // The tab's own listener on the port, which the last stop ended, lets go of it first.
            let previous = stopping.filter { $0.requestedPort == forward.localPort }
            Task { [weak self] in
                for listener in previous {
                    await listener.stopped()
                }
                let result: Result<UInt16, ForwardListenError>
                do throws(ForwardListenError) {
                    result = .success(try await listener.start())
                } catch {
                    result = .failure(error)
                }
                self?.listener(id, started: result, generation: generation)
            }
        }
    }

    /// Stops every listener, and the connections they accepted, at once. The forwards that are on
    /// wait for the next start.
    func stop() {
        generation += 1
        for listener in listeners.values {
            listener.stop()
            stopping.append(listener)
            // Once it has let go of its port, nothing waits for it.
            Task { [weak self] in
                await listener.stopped()
                self?.stopping.removeAll { $0 === listener }
            }
        }
        listeners = [:]
        for index in forwards.indices where forwards[index].state != .off {
            forwards[index].state = .waiting
        }
    }

    /// The listener of the forward `id`, as the start `generation` made it.
    func listener(for id: PortForward.ID) -> PortForwardListener? {
        listeners[id]
    }

    private func listener(_ id: PortForward.ID, started result: Result<UInt16, ForwardListenError>, generation: Int) {
        guard generation == self.generation, let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let port):
            forwards[index].state = .listening(port: port, problem: nil)
        case .failure(.stopped):
            break
        case .failure(let error):
            Self.logger.notice("A forward couldn’t listen: \(error.description, privacy: .public)")
            listeners.removeValue(forKey: id)?.stop()
            forwards[index].state = .failed(error.description)
        }
    }

    private func listener(_ id: PortForward.ID, reported activity: PortForwardListener.Activity, generation: Int) {
        guard generation == self.generation, let index = forwards.firstIndex(where: { $0.id == id }),
            case .listening(let port, _) = forwards[index].state
        else { return }
        switch activity {
        case .opened:
            forwards[index].state = .listening(port: port, problem: nil)
        case .closed:
            break
        case .failed(let problem):
            forwards[index].state = .listening(port: port, problem: problem)
        case .stoppedListening(let reason):
            listeners.removeValue(forKey: id)?.stop()
            forwards[index].state = .failed(reason)
        }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Forwards")
}

/// How one of a tab's port forwards stands.
public enum ForwardState: Equatable, Sendable {
    /// Switched off in the host: it never listens.
    case off
    /// It listens once the tab's connection works and Shello is in the foreground.
    case waiting
    /// It is about to listen.
    case starting
    /// It listens on 127.0.0.1, on `port`. `problem` says why the last connection it accepted did
    /// not reach its destination, until one does.
    case listening(port: UInt16, problem: String?)
    /// It could not listen, or stopped listening, for this reason, said in a sentence.
    case failed(String)
}
