import Foundation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import Synchronization
import Testing

@testable import ShelloCore

/// The network and the server behind tabs, as a test makes them behave: each try to connect
/// succeeds or fails as queued, and each connection it makes can then be lost, its shell end, its
/// keepalive go unanswered, or its path change.
final class FakeServer: TabConnector {
    /// How a try to connect ends.
    enum Outcome: Sendable {
        case connects
        case fails(SSHError)
        /// Asks to trust `key`, then connects if the user trusts it.
        case asksToTrust(HostKey)
        /// Waits until the try is cancelled.
        case hangs
    }

    private struct State {
        var outcomes: [Outcome] = []
        var tries = 0
        var connections: [FakeConnection] = []
        var keepaliveAnswers = true
        var tmux = FakeTmux.installed("tmux 3.4\n")
    }

    private let state = Mutex(State())

    /// How the next tries end, in order; once these are used up, tries connect.
    func queue(_ outcomes: Outcome...) {
        state.withLock { $0.outcomes += outcomes }
    }

    /// Whether the keepalives of the connections made from now on are answered.
    func setKeepaliveAnswers(_ answers: Bool) {
        state.withLock { $0.keepaliveAnswers = answers }
    }

    /// How tmux answers on the hidden channels of the connections made from now on.
    func setTmux(_ tmux: FakeTmux) {
        state.withLock { $0.tmux = tmux }
    }

    var tries: Int { state.withLock(\.tries) }
    var connections: [FakeConnection] { state.withLock(\.connections) }
    var lastConnection: FakeConnection? { connections.last }

    func openConnection(
        to host: Host, progress: @escaping @Sendable (ConnectStep) async -> Void,
        askToTrust: @escaping @Sendable (Server, HostKey) async -> Bool,
        answer: @escaping @Sendable (KeyboardInteractiveChallenge) async -> [Secret]?
    ) async throws -> any TabConnection {
        let outcome = state.withLock { state in
            state.tries += 1
            return state.outcomes.isEmpty ? .connects : state.outcomes.removeFirst()
        }
        await progress(.verifyingHostKey)
        switch outcome {
        case .connects:
            break
        case .fails(let error):
            throw error
        case .asksToTrust(let key):
            guard await askToTrust(host.server, key) else { throw ConnectError.hostKeyNotTrusted }
        case .hangs:
            try await Task.sleep(for: .seconds(3600))
        }
        await progress(.signingIn)
        let connection = state.withLock { state in
            let connection = FakeConnection(answersKeepalives: state.keepaliveAnswers, tmux: state.tmux)
            state.connections.append(connection)
            return connection
        }
        return connection
    }

    func replaceTrustedKey(_ trusted: TrustedHostKey, with presented: HostKey, of server: Server) async throws {}
}

/// How tmux answers on a fake connection's hidden channels.
enum FakeTmux: Sendable {
    /// `tmux -V` prints this.
    case installed(String)
    /// The shell does not find tmux.
    case missing
    /// The command never ends, until it is cancelled.
    case hangs
    /// The connection fails under the command.
    case fails(SSHError)
}

/// A signed-in connection that a test drops when it chooses.
final class FakeConnection: TabConnection {
    let shell = FakeShell()
    let pathEvents: AsyncStream<SSHConnection.PathEvent>
    private let pathContinuation: AsyncStream<SSHConnection.PathEvent>.Continuation

    private struct State {
        var isClosed = false
        var keepalives = 0
        var shellSizes: [TerminalSize] = []
        var answersKeepalives: Bool
        var tmux: FakeTmux
        var commands: [String] = []
        /// Whether a command was running when the shell was opened.
        var shellOpenedWhileACommandRan = false
        var runningCommands = 0
    }

    private let state: Mutex<State>

    /// The round trip each answered keepalive reports.
    static let roundTrip = Duration.milliseconds(24)

    init(answersKeepalives: Bool, tmux: FakeTmux = .installed("tmux 3.4\n")) {
        state = Mutex(State(answersKeepalives: answersKeepalives, tmux: tmux))
        (pathEvents, pathContinuation) = AsyncStream.makeStream()
    }

    var isClosed: Bool { state.withLock(\.isClosed) }
    var keepalives: Int { state.withLock(\.keepalives) }
    /// The sizes the shells were opened with.
    var shellSizes: [TerminalSize] { state.withLock(\.shellSizes) }
    /// The commands run on hidden channels, in order.
    var commands: [String] { state.withLock(\.commands) }
    /// Whether the shell was opened while a hidden channel's command still ran: a server that allows
    /// one session per connection (`MaxSessions 1`) would refuse it.
    var shellOpenedWhileACommandRan: Bool { state.withLock(\.shellOpenedWhileACommandRan) }

    func run(_ command: String) async throws -> SSHCommandResult {
        let tmux = state.withLock { state in
            state.commands.append(command)
            state.runningCommands += 1
            return state.tmux
        }
        defer { state.withLock { $0.runningCommands -= 1 } }
        switch tmux {
        case .installed(let version):
            return SSHCommandResult(output: Array(version.utf8), errorOutput: [], exitStatus: 0)
        case .missing:
            return SSHCommandResult(output: [], errorOutput: Array("sh: tmux: not found\n".utf8), exitStatus: 127)
        case .hangs:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        case .fails(let error):
            throw error
        }
    }

    var keyExchange: KeyExchange? {
        get async { nil }
    }

    func openShell(for host: Host, size: TerminalSize) async throws -> any TerminalByteStream {
        state.withLock { state in
            state.shellSizes.append(size)
            if state.runningCommands > 0 { state.shellOpenedWhileACommandRan = true }
        }
        return shell
    }

    func keepalive() async throws -> Duration {
        let answers = state.withLock { state in
            state.keepalives += 1
            return state.answersKeepalives
        }
        guard answers else {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        return Self.roundTrip
    }

    func close() async {
        state.withLock { $0.isClosed = true }
        shell.end()
        pathContinuation.finish()
    }

    /// The network drops the connection: the shell's output fails, as `SSHConnection`'s does.
    func lose() {
        shell.fail(SSHError.connectionLost("the network dropped the connection"))
    }

    /// The network under the connection changes.
    func path(_ event: SSHConnection.PathEvent) {
        pathContinuation.yield(event)
    }
}

/// A login shell that prints what the test says, and keeps what the terminal sent.
final class FakeShell: TerminalByteStream {
    let output: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let state = Mutex<(input: [UInt8], sizes: [TerminalSize])>(([], []))

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    /// Everything the terminal sent, as text.
    var input: String { state.withLock { String(decoding: $0.input, as: UTF8.self) } }
    /// The sizes the terminal reported, in order.
    var sizes: [TerminalSize] { state.withLock(\.sizes) }

    func send(_ bytes: [UInt8]) {
        state.withLock { $0.input += bytes }
    }

    func resize(to size: TerminalSize) {
        state.withLock { $0.sizes.append(size) }
    }

    func print(_ text: String) {
        continuation.yield(Array(text.utf8))
    }

    /// The shell exits.
    func end() {
        continuation.finish()
    }

    func fail(_ error: SSHError) {
        continuation.finish(throwing: error)
    }
}

/// A terminal that keeps everything it was shown, as its scrollback, and counts what the tab did.
@MainActor
final class FakeTerminal: TabTerminal {
    private(set) var size = TerminalSize(columns: 80, rows: 24)
    /// Everything every stream printed, and Shello's notes, in order.
    private(set) var text = ""
    private(set) var attachments = 0
    private(set) var preparations = 0
    /// Shello's notes, in order.
    private(set) var notes: [String] = []
    private var stream: (any TerminalByteStream)?
    private var reader: Task<Void, Never>?

    func attach<Stream: TerminalByteStream>(_ stream: Stream) {
        detach()
        attachments += 1
        self.stream = stream
        stream.resize(to: size)
        let output = stream.output
        reader = Task { [weak self] in
            do {
                for try await chunk in output {
                    self?.text += String(decoding: chunk, as: UTF8.self)
                }
            } catch {}
        }
    }

    func detach() {
        reader?.cancel()
        reader = nil
        stream = nil
    }

    func prepareForNextConnection() {
        preparations += 1
    }

    func showNote(_ note: String) {
        notes.append(note)
        text += "Shello: \(note)\r\n"
    }

    /// The user resized the terminal, as rotating the device does.
    func resize(to size: TerminalSize) {
        self.size = size
        stream?.resize(to: size)
    }

    func type(_ text: String) {
        stream?.send(Array(text.utf8))
    }
}

/// The device's network, as the test turns it on and off.
final class FakeNetworkMonitor: NetworkMonitor {
    private let state = Mutex<(isAvailable: Bool, continuations: [AsyncStream<Bool>.Continuation])>((true, []))

    func updates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let isAvailable = state.withLock { state in
            state.continuations.append(continuation)
            return state.isAvailable
        }
        continuation.yield(isAvailable)
        return stream
    }

    func set(available isAvailable: Bool) {
        let continuations = state.withLock { state in
            state.isAvailable = isAvailable
            return state.continuations
        }
        for continuation in continuations {
            continuation.yield(isAvailable)
        }
    }
}

/// The waits the tabs asked for, which then pass in real time: the tests choose short ones.
final class RecordingSleep: Sendable {
    private let requested = Mutex<[Duration]>([])

    /// Every wait asked for, in order.
    var durations: [Duration] { requested.withLock { $0 } }

    func sleep(_ duration: Duration) async throws {
        requested.withLock { $0.append(duration) }
        try await Task.sleep(for: duration)
    }
}

/// Tabs on a fake server, each with a fake terminal, whose waits are recorded.
@MainActor
struct TabTest {
    let server = FakeServer()
    let network = FakeNetworkMonitor()
    let sleep = RecordingSleep()
    let tabs: TerminalTabs<FakeTerminal>

    /// The waits after each failed try to reconnect: short, and each different from the others.
    static let policy = ReconnectPolicy(delays: [.milliseconds(11), .milliseconds(22), .milliseconds(44)])

    init(viabilityGrace: Duration = .milliseconds(200)) {
        let sleep = sleep
        tabs = TerminalTabs(
            services: TabServices(
                connector: server, network: network, reconnectPolicy: Self.policy, viabilityGrace: viabilityGrace,
                sleep: { try await sleep.sleep($0) }),
            makeTerminal: { _ in FakeTerminal() })
    }

    /// A host whose keepalive comes every `keepalive`: by default too rarely to matter after the
    /// first, which goes at once.
    static func host(
        _ name: String = "nas", startupCommand: String = "", keepalive: Duration = .seconds(3600)
    ) -> Host {
        Host(
            name: name, address: "\(name).lan", username: "admin", authMethod: .password,
            startupCommand: startupCommand, keepaliveInterval: keepalive)
    }

    /// Opens a tab for `host` and waits until it is active.
    func openActiveTab(_ host: Host = TabTest.host()) async throws -> TerminalTab<FakeTerminal> {
        let tab = tabs.open(host)
        await waitUntil { tab.state == .active }
        try #require(tab.state == .active)
        return tab
    }
}

/// Waits until `condition` holds, for at most `timeout`, checking every few milliseconds.
@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
