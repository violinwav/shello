import Foundation
import Observation
import ShelloModel
import ShelloSSH
import os

/// A tab's port forwards (README section 4), as its host had them when the tab last connected, and
/// how each one stands, for the Connection sheet.
///
/// Local and dynamic forwards listen on this device's loopback, which other apps on the device can
/// reach too, so they listen only while they are needed (STACK section 7.1): from the moment the
/// tab's connection is signed in and its session started, while Shello is in the foreground, until
/// the connection drops or closes, or Shello leaves the foreground. A reconnect, or Shello's return to
/// the foreground with the connection still open, listens again.
///
/// Remote forwards have the server listen instead, and open nothing on the device that another app
/// could reach: they are requested once the connection is signed in and its session started, and
/// last as long as the connection, Shello's background time included. They are cancelled as the
/// connection closes, and requested again after a reconnect.
///
/// A forward whose port is taken, here or on the server, fails on its own, and says so; the others
/// listen.
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
    @ObservationIgnored private var remoteListeners: [PortForward.ID: RemoteForwardListener] = [:]
    /// The listeners stopped whose ports the system has not let go of yet: a new listener on the same
    /// port waits for them, so that a reconnect does not find its own port in use.
    @ObservationIgnored private var stopping: [PortForwardListener] = []
    /// The remote forwards stopped whose cancel the server has not answered yet.
    @ObservationIgnored private var stoppingRemote: [RemoteForwardListener] = []
    /// Counts the starts and stops of the local and dynamic forwards, and of the remote ones, so that
    /// what a listener reports after a stop changes nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var remoteGeneration = 0

    init() {}

    isolated deinit {
        for listener in listeners.values {
            listener.stop()
        }
        for listener in remoteListeners.values {
            listener.stop()
        }
    }

    /// Whether any forward is listening or starting to.
    public var isActive: Bool {
        forwards.contains { $0.state.isActive }
    }

    /// Whether any local or dynamic forward, on this device's loopback, is listening or starting to.
    var isActiveOnDevice: Bool {
        forwards.contains { !$0.forward.isRemote && $0.state.isActive }
    }

    /// Takes the host's forwards, as they are when the tab connects: none listens yet. Those
    /// switched off stay off.
    func set(_ portForwards: [PortForward]) {
        stop()
        forwards = portForwards.map { Forward(forward: $0, state: $0.isEnabled ? .waiting : .off) }
    }

    /// Listens for each local and dynamic forward that is on, and carries each connection it accepts
    /// through a tunnel from `open`. Each forward that cannot listen fails alone.
    func startOnDevice(opening open: @escaping ForwardTunnelOpener) {
        stopOnDevice()
        generation += 1
        let generation = generation
        for index in forwards.indices where forwards[index].state != .off {
            let forward = forwards[index].forward
            let target: PortForwardListener.Target
            switch forward.kind {
            case .local(let destination): target = .destination(address: destination.address, port: destination.port)
            case .dynamic: target = .socks
            case .remote: continue
            }
            let id = forward.id
            let listener = PortForwardListener(
                port: forward.port, target: target, open: open,
                report: { [weak self] activity in
                    Task { @MainActor in self?.listener(id, reported: activity, generation: generation) }
                })
            listeners[id] = listener
            forwards[index].state = .starting
            // The tab's own listener on the port, which the last stop ended, lets go of it first.
            let previous = stopping.filter { $0.requestedPort == forward.port }
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

    /// Has the server listen for each remote forward that is on, over `forwarding`, the tab's
    /// connection, and carries each connection it forwards to the forward's destination. Each one the
    /// server refuses fails alone, with what the server answered.
    func startRemote(over forwarding: any RemoteForwarding) {
        stopRemote()
        remoteGeneration += 1
        let generation = remoteGeneration
        for index in forwards.indices where forwards[index].state != .off {
            let forward = forwards[index].forward
            guard case .remote(let bindAddress, let destination) = forward.kind else { continue }
            let id = forward.id
            let listener = RemoteForwardListener(
                port: forward.port, bindAddress: bindAddress, destination: destination, over: forwarding,
                report: { [weak self] activity in
                    Task { @MainActor in self?.remote(id, reported: activity, generation: generation) }
                })
            remoteListeners[id] = listener
            forwards[index].state = .starting
            Task { [weak self] in
                let result: Result<UInt16, ForwardListenError>
                do throws(ForwardListenError) {
                    result = .success(try await listener.start())
                } catch {
                    result = .failure(error)
                }
                self?.remote(id, started: result, generation: generation)
            }
        }
    }

    /// Stops every forward at once: the listeners on this device and the connections they accepted,
    /// and the remote forwards, whose cancel goes to the server (`stopped()` waits for it). The
    /// forwards that are on wait for the next start.
    func stop() {
        stopOnDevice()
        stopRemote()
    }

    /// Stops the local and dynamic forwards' listeners, and the connections they accepted, at once, as
    /// Shello leaves the foreground. They wait for the next start; the remote forwards go on.
    func stopOnDevice() {
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
        for index in forwards.indices where !forwards[index].forward.isRemote && forwards[index].state != .off {
            forwards[index].state = .waiting
        }
    }

    /// Stops the remote forwards: the connections the server forwarded end, and the server is asked
    /// to stop listening.
    private func stopRemote() {
        remoteGeneration += 1
        for listener in remoteListeners.values {
            listener.stop()
            stoppingRemote.append(listener)
            Task { [weak self] in
                await listener.stopped()
                self?.stoppingRemote.removeAll { $0 === listener }
            }
        }
        remoteListeners = [:]
        for index in forwards.indices where forwards[index].forward.isRemote && forwards[index].state != .off {
            forwards[index].state = .waiting
        }
    }

    /// Returns once the server answered the cancels of the remote forwards stopped, or `timeout`
    /// passed: the tab's connection closes after them, so that the server hears each cancel before
    /// the connection ends, which ends its listening anyway.
    func remoteStopped(timeout: Duration = .seconds(1)) async {
        let stopping = stoppingRemote
        guard !stopping.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for listener in stopping {
                    await listener.stopped()
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    /// The listener of the local or dynamic forward `id`, as the start `generation` made it.
    func listener(for id: PortForward.ID) -> PortForwardListener? {
        listeners[id]
    }

    /// The remote forward `id`, as the last remote start made it.
    func remoteListener(for id: PortForward.ID) -> RemoteForwardListener? {
        remoteListeners[id]
    }

    private func listener(_ id: PortForward.ID, started result: Result<UInt16, ForwardListenError>, generation: Int) {
        guard generation == self.generation else { return }
        started(id, result) { listeners.removeValue(forKey: id)?.stop() }
    }

    private func remote(_ id: PortForward.ID, started result: Result<UInt16, ForwardListenError>, generation: Int) {
        guard generation == remoteGeneration else { return }
        started(id, result) { remoteListeners.removeValue(forKey: id)?.stop() }
    }

    /// The forward `id` started, or not: `discard` ends what is left of one that failed.
    private func started(_ id: PortForward.ID, _ result: Result<UInt16, ForwardListenError>, discard: () -> Void) {
        guard let index = forwards.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let port):
            forwards[index].state = .listening(port: port, problem: nil)
        case .failure(.stopped):
            break
        case .failure(let error):
            Self.logger.notice("A forward couldn’t listen: \(error.description, privacy: .public)")
            discard()
            forwards[index].state = .failed(error.description)
        }
    }

    private func listener(_ id: PortForward.ID, reported activity: PortForwardListener.Activity, generation: Int) {
        guard generation == self.generation else { return }
        reported(id, activity) { listeners.removeValue(forKey: id)?.stop() }
    }

    private func remote(_ id: PortForward.ID, reported activity: PortForwardListener.Activity, generation: Int) {
        guard generation == remoteGeneration else { return }
        reported(id, activity) { remoteListeners.removeValue(forKey: id)?.stop() }
    }

    /// What the forward `id` reported, while it listens: `discard` ends one that stopped listening.
    private func reported(_ id: PortForward.ID, _ activity: PortForwardListener.Activity, discard: () -> Void) {
        guard let index = forwards.firstIndex(where: { $0.id == id }),
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
            discard()
            forwards[index].state = .failed(reason)
        }
    }

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "Forwards")
}

/// How one of a tab's port forwards stands.
public enum ForwardState: Equatable, Sendable {
    /// Switched off in the host: it never listens.
    case off
    /// It listens once the tab's connection works, and, unless it is a remote forward, while Shello
    /// is in the foreground.
    case waiting
    /// It is about to listen, or the server was asked to.
    case starting
    /// It listens on `port`: on 127.0.0.1 for a local or dynamic forward, on the server for a remote
    /// one. `problem` says why the last connection it accepted did not reach its destination, until
    /// one does.
    case listening(port: UInt16, problem: String?)
    /// It could not listen, or stopped listening, for this reason, said in a sentence.
    case failed(String)

    /// Whether it listens or is starting to.
    var isActive: Bool {
        switch self {
        case .starting, .listening: true
        case .off, .waiting, .failed: false
        }
    }
}
