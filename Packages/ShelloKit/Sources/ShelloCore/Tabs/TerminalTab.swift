import Foundation
import Observation
import ShelloModel
import ShelloSSH
import ShelloSecurity
import ShelloStorage
import ShelloTmux
import os

/// A tab (GLOSSARY): a terminal, and the connections behind it, one after the other (README section
/// 4). It connects, has the user trust a new host key, blocks a changed one until the user replaces
/// it, signs in, asking the server's keyboard-interactive questions, starts the login shell, attaches
/// the terminal to it, runs the host's startup command, and attaches the host's tmux session when
/// the host has auto-attach on (README section 8), so that a reconnect reattaches it.
///
/// While it is active, a keepalive checks the connection every keepalive interval, and its round
/// trip is the tab's latency. When the connection drops, because the network went or the server
/// stopped answering, the tab reconnects: at once, then with waits that grow (`ReconnectPolicy`), and
/// while the device has no network, as soon as it is back. The terminal keeps what it showed.
///
/// Through jump hosts (README section 3), the tab's connection is the whole route
/// (`RouteConnection`), connected hop by hop. Each hop's host key and sign-in is asked about with
/// the hop named, and a hop that drops reconnects the whole route.
///
/// `TerminalTabs` makes and closes tabs; the screens show them and answer their questions.
@MainActor
@Observable
public final class TerminalTab<Terminal: TabTerminal>: Identifiable {
    public let id = UUID()
    /// The host the tab connects to, as it was when the tab last connected.
    public private(set) var host: Host
    /// The tab's terminal, which keeps its scrollback while connections come and go.
    public let terminal: Terminal
    public private(set) var state = TabState.connecting(.connecting)
    /// The round trip of the last keepalive, while the tab is active (README section 4).
    public private(set) var latency: Duration?
    /// The key exchange the last connection to the tab's host negotiated (README section 14).
    public private(set) var keyExchange: KeyExchange?
    /// The key exchange of each connection along the route of the last connection, in its order,
    /// the tab's host's last (README section 14).
    public private(set) var keyExchanges: [RouteKeyExchange] = []
    /// The route of the last connection, or of the one being made (README section 3).
    public private(set) var route: Route?
    /// The jump host the connection being made is at, while it is at one; nil once it is at the
    /// tab's own host, and while no connection is being made.
    public private(set) var currentJumpHost: Host?
    /// The host key the trust sheet asks about, while it waits for the user.
    public private(set) var trustQuestion: TrustQuestion?
    /// The keyboard-interactive questions the sign-in sheet asks, while it waits for the user.
    public private(set) var signInQuestion: SignInQuestion?
    /// Whether the server is asking keyboard-interactive questions: the sign-in sheet stays up from
    /// the first round of questions until signing in ends, and waits for the server between rounds.
    public private(set) var isSigningIn = false
    /// The changed host key the block sheet shows.
    public private(set) var hostKeyChange: HostKeyChange?
    /// Whether the trusted host key is being replaced: the user is asked to authenticate.
    public private(set) var isReplacingHostKey = false
    /// Why the trusted host key was not replaced, for the block sheet.
    public private(set) var replacementProblem: String?
    /// How many connections the tab has had: a reconnect makes one more.
    public private(set) var connectionCount = 0
    /// How long the last connection took, from the moment it was asked for to the shell's first
    /// output, its prompt: README section 16's "tap to usable prompt" for the first connection.
    public private(set) var timeToPrompt: Duration?
    /// What the last connection did about the host's tmux session, when the host has auto-attach on
    /// (README section 8): attached it, or ran a plain shell, and why. Nil with auto-attach off.
    public private(set) var tmux: TmuxAttachment?

    /// Why the last connection runs a plain shell although the host attaches a tmux session: the
    /// note the terminal shows, for VoiceOver to hear with the connection. Nil otherwise.
    public var plainShellNote: String? {
        guard case .plainShell(let fallback)? = tmux else { return nil }
        return fallback.note
    }

    /// The hidden channels (GLOSSARY) of the tab's connection while it is active, for Shello's own
    /// commands on the server it signed in to, such as installing an SSH key there (README section
    /// 13); nil while the tab has no connection that works. A command on them fails with the
    /// connection's `SSHError` if the connection drops under it.
    public var hiddenChannels: (any HiddenChannels)? {
        state == .active ? connection : nil
    }

    /// Installs `key` on the server the tab is signed in to (README section 13), over a hidden
    /// channel of its connection, as `AuthorizedKeys.install(_:on:)` does.
    /// - Throws: `KeyInstallationError.notConnected` while the tab has no connection that works; as
    ///   `AuthorizedKeys.install(_:on:)` otherwise.
    public func installSSHKey(_ key: SSHKey) async throws -> KeyInstallation {
        guard let channels = hiddenChannels else { throw KeyInstallationError.notConnected }
        return try await AuthorizedKeys.install(key, on: channels)
    }

    /// The question the tab waits for the user to answer: to trust a new host key, or the server's
    /// questions, round after round, in one sheet.
    public var prompt: Prompt? {
        if let trustQuestion { return .trust(trustQuestion) }
        return isSigningIn ? .signIn : nil
    }

    public enum Prompt: Identifiable, Equatable, Sendable {
        case trust(TrustQuestion)
        case signIn

        public var id: String {
            switch self {
            case .trust(let question): "trust-\(question.id)"
            case .signIn: "sign-in"
            }
        }
    }

    @ObservationIgnored private let services: TabServices
    @ObservationIgnored private let conditions: TabConditions
    /// Called when the tab's first connection stopped because the user declined: the host key, or
    /// the server's questions. A tab that never connected has nothing to keep, so it closes.
    @ObservationIgnored private let declined: @MainActor (TerminalTab) -> Void
    @ObservationIgnored private var connection: (any TabConnection)?
    /// The connection being made.
    @ObservationIgnored private var attempt: Task<Void, Never>?
    /// The wait before the next try to reconnect.
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// The keepalive and the watch on the network, while the tab is active.
    @ObservationIgnored private var watchers: [Task<Void, Never>] = []
    /// The countdown that gives up on a connection whose network went, unless it comes back.
    @ObservationIgnored private var viabilityTimeout: Task<Void, Never>?
    @ObservationIgnored private var isViable = true
    /// Counts the tries to connect, so that what an earlier one reports changes nothing.
    @ObservationIgnored private var generation = 0
    /// How far the try to connect is along the route, which only goes forward.
    @ObservationIgnored private var routeProgress: RouteProgress?
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private var lastFailure = ""
    @ObservationIgnored private var trustAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var signInAnswer: CheckedContinuation<[Secret]?, Never>?
    @ObservationIgnored private var promptInterval: (state: OSSignpostIntervalState, start: ContinuousClock.Instant)?

    /// A tab for `host`, which connects once it starts; or, `isRestored`, a tab that Restore
    /// recreated, which waits in `TabState.restored` until it is resumed.
    init(
        host: Host, terminal: Terminal, services: TabServices, conditions: TabConditions, isRestored: Bool = false,
        declined: @escaping @MainActor (TerminalTab) -> Void
    ) {
        self.host = host
        self.terminal = terminal
        self.services = services
        self.conditions = conditions
        self.declined = declined
        if isRestored {
            state = .restored
        }
    }

    isolated deinit {
        attempt?.cancel()
        retry?.cancel()
        viabilityTimeout?.cancel()
        for watcher in watchers { watcher.cancel() }
        trustAnswer?.resume(returning: false)
        signInAnswer?.resume(returning: nil)
        if let connection {
            Task { await connection.close() }
        }
    }

    // MARK: - Connecting

    /// Connects for the first time.
    func start() {
        guard attempt == nil, connectionCount == 0 else { return }
        tryToConnect()
    }

    /// Connects again now, as the user asks: after the shell ended, after the tab gave up, or while
    /// it waits for its next try, or for its first one after Restore. The waits start over.
    public func reconnect() {
        switch state {
        case .active, .closed:
            return
        case .connecting(let step) where step > .connecting:
            return
        case .reconnecting(let reconnecting):
            if case .trying(let step) = reconnecting.phase, step > .connecting { return }
        case .connecting, .suspended, .restored, .ended, .disconnected:
            break
        }
        cancelAttempt()
        failedAttempts = 0
        hostKeyChange = nil
        tryToConnect()
    }

    /// Reconnects a tab whose connection Shello closed in the background, now that it is on screen
    /// again (README section 4), or one that waits for Shello to be unlocked. A tab that Restore
    /// recreated makes its first connection.
    func resume() {
        switch state {
        case .suspended, .restored:
            failedAttempts = 0
            tryToConnect()
        case .reconnecting(let reconnecting) where reconnecting.phase == .waitingForUnlock:
            tryToConnect()
        case .connecting, .active, .reconnecting, .ended, .disconnected, .closed:
            break
        }
    }

    /// Shello's foreground, its lock or the network changed: a tab that waits for them tries now.
    func conditionsChanged() {
        guard case .reconnecting(let reconnecting) = state else { return }
        switch reconnecting.phase {
        case .waitingForNetwork:
            guard conditions.isNetworkAvailable else { return }
            // Back on the network: the waits start over.
            failedAttempts = 0
            tryToConnect()
        case .waitingForUnlock:
            if conditions.canConnect { tryToConnect() }
        case .trying, .waiting:
            break
        }
    }

    /// Makes a connection now, or waits for what it needs first: Shello unlocked and in the
    /// foreground, and a network.
    private func tryToConnect() {
        retry?.cancel()
        retry = nil
        let isReconnect = connectionCount > 0
        if isReconnect {
            guard conditions.canConnect else {
                state = .reconnecting(
                    Reconnecting(phase: .waitingForUnlock, failedAttempts: failedAttempts, reason: lastFailure))
                return
            }
            guard conditions.isNetworkAvailable else {
                state = .reconnecting(
                    Reconnecting(phase: .waitingForNetwork, failedAttempts: failedAttempts, reason: lastFailure))
                return
            }
        }
        generation += 1
        let generation = generation
        routeProgress = nil
        currentJumpHost = nil
        state =
            isReconnect
            ? .reconnecting(
                Reconnecting(phase: .trying(.connecting), failedAttempts: failedAttempts, reason: lastFailure))
            : .connecting(.connecting)
        let signposter = TabLog.signposter
        promptInterval = (
            signposter.beginInterval(
                "Prompt", id: signposter.makeSignpostID(), "\(isReconnect ? "reconnect" : "first")"),
            .now
        )
        attempt = Task { [weak self] in
            await self?.connect(generation: generation, isReconnect: isReconnect)
        }
    }

    private func connect(generation: Int, isReconnect: Bool) async {
        defer {
            if generation == self.generation {
                isSigningIn = false
                currentJumpHost = nil
                attempt = nil
            }
        }
        var opened: (any TabConnection)?
        do {
            let host = await services.refreshedHost(host)
            self.host = host
            // Before anything goes over the network: a route Shello refuses, such as one with a
            // missing jump host, never connects directly instead.
            let route = try await services.route(to: host)
            try checkCurrent(generation)
            self.route = route
            currentJumpHost = route.jumpHosts.first
            let connection = try await services.connector.openConnection(
                along: route,
                progress: { [weak self] progress in await self?.setProgress(progress, generation: generation) },
                askToTrust: { [weak self] hop, key in await self?.askToTrust(hop, key) ?? false },
                answer: { [weak self] hop, challenge in await self?.askToSignIn(hop, challenge) })
            opened = connection
            try checkCurrent(generation)
            isSigningIn = false
            keyExchange = await connection.keyExchange
            let keyExchanges = await connection.keyExchanges
            self.keyExchanges = zip(route.hops, keyExchanges).map { hop, keyExchange in
                RouteKeyExchange(hostName: hop.name, server: hop.server, keyExchange: keyExchange)
            }
            setProgress(RouteProgress(hop: route.hops.count - 1, step: .startingSession), generation: generation)
            try await startSession(on: connection, generation: generation, isReconnect: isReconnect)
            try checkCurrent(generation)
            becameActive(connection, generation: generation)
        } catch {
            if let opened {
                Task { await opened.close() }
            }
            guard generation == self.generation else { return }
            attemptFailed(error, isReconnect: isReconnect)
        }
    }

    /// Starts the tab's session on a new connection, once it is signed in: the user's login shell,
    /// attached to the terminal, then the host's startup command, typed once the shell shows its
    /// prompt, so that what it sets, such as `export`, holds in the shell (README section 3).
    ///
    /// With auto-attach on (README section 8), a hidden channel checks the server's tmux before the
    /// shell opens, and the command that attaches the host's tmux session, or starts it, is typed
    /// after the startup command: the startup command runs in the login shell, outside tmux, where
    /// what it sets reaches a tmux session that starts now, and never into a program left running in
    /// a session it reattaches. Without a tmux it can use, the tab runs a plain shell, and its
    /// terminal says why. Every connection goes through here, the first and each reconnect, so a
    /// reconnect reattaches the same tmux session.
    private func startSession(on connection: any TabConnection, generation: Int, isReconnect: Bool) async throws {
        if isReconnect {
            terminal.prepareForNextConnection()
        }
        // Before the shell, not beside it: a server that allows one session per connection
        // (`MaxSessions 1`) would refuse the second channel.
        let tmux = try await tmuxAttachment(on: connection)
        try checkCurrent(generation)
        let shell = try await connection.openShell(for: host, size: terminal.size)
        try checkCurrent(generation)
        self.tmux = tmux
        if case .plainShell(let fallback) = tmux {
            terminal.showNote(fallback.note)
        }
        let watch = OutputWatch(
            onFirstOutput: { [weak self] in
                Task { @MainActor in self?.firstOutputArrived(generation: generation) }
            },
            onEnd: { [weak self] failure in
                let reason = failure.map { String(describing: $0) }
                Task { @MainActor in self?.outputEnded(failure: reason, generation: generation) }
            })
        attach(shell, watch: watch)
        let command = StartupCommand(host.startupCommand)
        let attachKeys = tmux.flatMap(TmuxAttachKeys.init)
        guard command != nil || attachKeys != nil else { return }
        await waitForPrompt(watch)
        try checkCurrent(generation)
        if let command {
            shell.send(command.bytes)
        }
        if let attachKeys {
            shell.send(attachKeys.bytes)
        }
    }

    /// How the connection starts with the host's tmux session, when the host has auto-attach on:
    /// the server's tmux is checked on a hidden channel, within the host's connect timeout, as
    /// connecting is. Nil with auto-attach off.
    /// - Throws: What the connection throws when it is gone under the check, or `CancellationError`.
    private func tmuxAttachment(on connection: any TabConnection) async throws -> TmuxAttachment? {
        guard host.tmuxAutoAttach else { return nil }
        let sessionName = host.tmuxSessionName
        do {
            return try await withTimeout(host.connectTimeout, sleep: services.sleep) {
                try await Tmux.attachment(sessionName: sessionName, on: connection)
            }
        } catch is TimedOut {
            TabLog.logger.notice("tmux did not answer within the connect timeout")
            return .plainShell(.unknown("tmux didn’t answer in time"))
        }
    }

    private func attach<Shell: TerminalByteStream>(_ shell: Shell, watch: OutputWatch) {
        terminal.attach(TabStream(shell, watch: watch))
    }

    /// Waits until the shell has shown its prompt: it printed, then went quiet. A shell that keeps
    /// printing, or prints nothing, gets the command after a few seconds all the same.
    private func waitForPrompt(_ watch: OutputWatch) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !watch.isQuiet(for: .milliseconds(150)), !watch.hasEnded, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func becameActive(_ connection: any TabConnection, generation: Int) {
        self.connection = connection
        connectionCount += 1
        failedAttempts = 0
        lastFailure = ""
        latency = nil
        isViable = true
        state = .active
        TabLog.logger.info("Tab active after \(self.connectionCount) connection(s)")
        watchers = [
            Task { [weak self] in await self?.keepAlive(connection, generation: generation) },
            Task { [weak self] in await self?.watchPath(of: connection, generation: generation) },
        ]
        if let hosts = services.hosts {
            let hostID = host.id
            Task {
                do {
                    try await hosts.recordConnection(toHost: hostID, at: .now)
                } catch {
                    TabLog.logger.error("Could not record the connection: \(error)")
                }
            }
        }
    }

    private func firstOutputArrived(generation: Int) {
        guard generation == self.generation, let promptInterval else { return }
        timeToPrompt = .now - promptInterval.start
        TabLog.signposter.endInterval("Prompt", promptInterval.state)
        self.promptInterval = nil
    }

    /// The try `generation` reached `progress` along its route: its state shows the step at the hop
    /// it is at, and `currentJumpHost` that hop while it is a jump host. Progress only goes forward:
    /// a report that arrives late changes nothing.
    private func setProgress(_ progress: RouteProgress, generation: Int) {
        guard generation == self.generation, progress > routeProgress ?? RouteProgress(hop: 0, step: .connecting)
        else { return }
        routeProgress = progress
        if let route, progress.hop < route.hops.count - 1 {
            currentJumpHost = route.hops[progress.hop]
        } else {
            currentJumpHost = nil
        }
        switch state {
        case .connecting:
            state = .connecting(progress.step)
        case .reconnecting(let reconnecting):
            guard case .trying = reconnecting.phase else { return }
            state = .reconnecting(
                Reconnecting(phase: .trying(progress.step), failedAttempts: failedAttempts, reason: lastFailure))
        case .active, .suspended, .restored, .ended, .disconnected, .closed:
            break
        }
    }

    /// Throws when a newer try, or closing the tab, took over from the try `generation`.
    private func checkCurrent(_ generation: Int) throws {
        if generation != self.generation || Task.isCancelled || state == .closed {
            throw CancellationError()
        }
    }

    private func attemptFailed(_ error: any Error, isReconnect: Bool) {
        // Said with the jump host it failed at, if it did, and handled as the failure itself.
        let reason = String(describing: error)
        let jumpHost = (error as? JumpHostError)?.jumpHost
        switch (error as? JumpHostError)?.error ?? error {
        case is CancellationError:
            return
        case ConnectError.hostKeyChanged(let server, let trusted, let presented):
            replacementProblem = nil
            hostKeyChange = HostKeyChange(
                server: server, trusted: trusted, presented: presented, hop: routeHop(for: jumpHost ?? host))
            state = .disconnected(
                jumpHost.map { "The host key of the jump host \($0.name) changed." } ?? "The server’s host key changed."
            )
        case ConnectError.hostKeyNotTrusted, ConnectError.signInCancelled:
            guard isReconnect else {
                state = .closed
                declined(self)
                return
            }
            state = .disconnected(reason)
        case is UnlockWindowClosed where isReconnect:
            // App lock engaged while Shello was away: the tab tries again once the user unlocks it.
            state = .reconnecting(
                Reconnecting(phase: .waitingForUnlock, failedAttempts: failedAttempts, reason: lastFailure))
        case let error where isReconnect && isWorthRetrying(error):
            failedAttempts += 1
            lastFailure = reason
            scheduleRetry()
        default:
            TabLog.logger.error("Could not connect: \(String(describing: error))")
            state = .disconnected(reason)
        }
    }

    /// Waits as the policy says before the next try, or gives up.
    private func scheduleRetry() {
        guard let delay = services.reconnectPolicy.delay(afterFailedAttempts: failedAttempts) else {
            state = .disconnected(lastFailure)
            return
        }
        state = .reconnecting(Reconnecting(phase: .waiting(delay), failedAttempts: failedAttempts, reason: lastFailure))
        let sleep = services.sleep
        retry = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            self?.tryToConnect()
        }
    }

    // MARK: - Active

    /// Checks the connection every keepalive interval, the first time at once, so that the tab
    /// shows its latency. A keepalive that the server has not answered after three intervals, as
    /// OpenSSH's `ServerAliveCountMax` counts, means the connection is gone.
    private func keepAlive(_ connection: any TabConnection, generation: Int) async {
        let interval = host.keepaliveInterval
        let sleep = services.sleep
        var isFirst = true
        while !Task.isCancelled {
            if !isFirst {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
            }
            isFirst = false
            do {
                let roundTrip = try await withTimeout(interval * 3, sleep: sleep) {
                    try await connection.keepalive()
                }
                guard generation == self.generation, state == .active else { return }
                latency = roundTrip
            } catch is TimedOut {
                connectionLost("The server stopped answering.", generation: generation)
                return
            } catch {
                // The connection failed: its shell's output says how.
                return
            }
        }
    }

    /// Follows the network under the connection (STACK section 7.1). A connection that is no
    /// longer viable may become viable again, as after a short drop of the Wi-Fi: the tab waits a
    /// moment for that, then reconnects. A better path while the connection is not viable, such as
    /// cellular once the Wi-Fi has gone, reconnects at once. A better path for a connection that
    /// works changes nothing: moving would end the shell.
    private func watchPath(of connection: any TabConnection, generation: Int) async {
        for await event in connection.pathEvents {
            guard generation == self.generation, state == .active else { return }
            switch event {
            case .viable(false):
                isViable = false
                startViabilityTimeout(generation: generation)
            case .viable(true):
                isViable = true
                viabilityTimeout?.cancel()
                viabilityTimeout = nil
            case .betterPathAvailable(true) where !isViable:
                connectionLost("The network changed.", generation: generation)
                return
            case .betterPathAvailable:
                break
            }
        }
    }

    private func startViabilityTimeout(generation: Int) {
        viabilityTimeout?.cancel()
        let grace = services.viabilityGrace
        let sleep = services.sleep
        viabilityTimeout = Task { [weak self] in
            do {
                try await sleep(grace)
            } catch {
                return
            }
            self?.connectionLost("The network connection was lost.", generation: generation)
        }
    }

    /// The shell's output ended: the shell ended, or the connection was lost.
    private func outputEnded(failure: String?, generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .active:
            if let failure {
                connectionLost(failure, generation: generation)
            } else {
                endConnection()
                state = .ended
            }
        case .connecting, .reconnecting:
            // The shell ended, or its connection failed, before the session had started.
            cancelAttempt()
            guard let failure else {
                state = .ended
                return
            }
            if connectionCount > 0 {
                failedAttempts += 1
                lastFailure = failure
                scheduleRetry()
            } else {
                state = .disconnected(failure)
            }
        case .suspended, .restored, .ended, .disconnected, .closed:
            break
        }
    }

    /// The connection is gone: the tab reconnects at once.
    private func connectionLost(_ reason: String, generation: Int) {
        guard generation == self.generation, state == .active else { return }
        TabLog.logger.notice("Connection lost: \(reason, privacy: .public)")
        endConnection()
        failedAttempts = 0
        lastFailure = reason
        tryToConnect()
    }

    /// Ends the connection that the tab had: its keepalive and watch stop, the terminal lets go of
    /// its stream and keeps what it shows, and the connection closes.
    private func endConnection() {
        generation += 1
        for watcher in watchers { watcher.cancel() }
        watchers = []
        viabilityTimeout?.cancel()
        viabilityTimeout = nil
        latency = nil
        terminal.detach()
        if let connection {
            self.connection = nil
            Task { await connection.close() }
        }
    }

    private func cancelAttempt() {
        generation += 1
        attempt?.cancel()
        attempt = nil
        retry?.cancel()
        retry = nil
        isSigningIn = false
        endTrustQuestion(false)
        answerSignIn(nil)
    }

    // MARK: - Background

    /// Closes the connection, cleanly and at once, as Shello leaves the background time iOS grants
    /// (README section 4): the tab reconnects once it is on screen again. A connection being made
    /// stops, whatever it waits for, Face ID included.
    func suspend() async {
        let pending = attempt
        let connection = connection
        switch state {
        case .connecting, .active, .reconnecting:
            cancelAttempt()
            endConnection()
            state = .suspended
        case .suspended, .restored, .ended, .disconnected, .closed:
            return
        }
        await connection?.close()
        await pending?.value
    }

    // MARK: - Closing

    /// Ends everything, at once: a connection being made, the connection, and a question still
    /// open. It never waits for the user, not even for Face ID (`HostConnector`). The task returned
    /// ends once the connection has closed and the connection being made has stopped.
    @discardableResult
    func close() -> Task<Void, Never> {
        let pending = attempt
        let connection = connection
        state = .closed
        cancelAttempt()
        endConnection()
        return Task {
            await connection?.close()
            await pending?.value
        }
    }

    // MARK: - Questions

    /// Shows the trust sheet for the server of `hop`, a host on the route, and waits for the user's
    /// answer.
    private func askToTrust(_ hop: Host, _ key: HostKey) async -> Bool {
        guard !Task.isCancelled, state != .closed else { return false }
        let place = routeHop(for: hop)
        return await withCheckedContinuation { continuation in
            trustAnswer = continuation
            trustQuestion = TrustQuestion(server: hop.server, key: key, hop: place)
        }
    }

    /// Where `hop` is on the route of the connection being made.
    private func routeHop(for hop: Host) -> RouteHop {
        guard let route, let index = route.hops.firstIndex(where: { $0.id == hop.id }) else {
            return RouteHop(name: hop.name, place: .direct)
        }
        return RouteHop(route, at: index)
    }

    /// The user's answer to the trust sheet that asks `question`. A sheet goes a moment after its
    /// question was answered, and the tab may ask its next one by then, such as the next hop's host
    /// key: a tap on the sheet as it goes changes nothing, so that no key is trusted unseen.
    public func answerTrust(_ trusts: Bool, to question: TrustQuestion) {
        guard question == trustQuestion else { return }
        endTrustQuestion(trusts)
    }

    /// Ends the wait for the trust sheet with `trusts`, if the tab waits for it.
    private func endTrustQuestion(_ trusts: Bool) {
        trustQuestion = nil
        trustAnswer?.resume(returning: trusts)
        trustAnswer = nil
    }

    /// Shows the sign-in sheet with the questions of the server of `hop`, a host on the route, and
    /// waits for the user's answers, or nil if they cancel.
    private func askToSignIn(_ hop: Host, _ challenge: KeyboardInteractiveChallenge) async -> [Secret]? {
        // A round that arrives after the user cancelled gets no sheet.
        guard !Task.isCancelled, state != .closed else { return nil }
        let place = routeHop(for: hop)
        return await withCheckedContinuation { continuation in
            signInAnswer = continuation
            signInQuestion = SignInQuestion(server: hop.server, challenge: challenge, hop: place)
            isSigningIn = true
        }
    }

    /// The user's answers to the sign-in sheet, one for each question, or nil if they cancelled.
    public func answerSignIn(_ answers: [Secret]?) {
        signInQuestion = nil
        signInAnswer?.resume(returning: answers)
        signInAnswer = nil
    }

    /// The user dismissed the sheet that showed `prompt`: no trust, or no answers. Between rounds of
    /// questions, while the server checks the last answers, nothing waits for an answer: signing in
    /// stops all the same.
    ///
    /// A prompt the tab no longer asks changes nothing. A sheet goes a moment after its question was
    /// answered, and on a fast connection the tab asks its next question by then, such as the next
    /// hop's host key: the user hasn't seen that one, which waits for its own sheet.
    public func dismissPrompt(_ prompt: Prompt) {
        guard prompt == self.prompt else { return }
        switch prompt {
        case .trust:
            endTrustQuestion(false)
        case .signIn:
            isSigningIn = false
            if signInAnswer != nil {
                answerSignIn(nil)
            } else {
                cancelAttempt()
                attemptFailed(ConnectError.signInCancelled, isReconnect: connectionCount > 0)
            }
        }
    }

    // MARK: - A changed host key

    /// Replaces the trusted host key with the one the server presented, once the user confirmed it
    /// on the block sheet and then authenticated (README section 3), and connects again.
    public func replaceTrustedHostKey() async {
        guard let change = hostKeyChange, !isReplacingHostKey else { return }
        isReplacingHostKey = true
        replacementProblem = nil
        defer { isReplacingHostKey = false }
        do {
            try await services.connector.replaceTrustedKey(change.trusted, with: change.presented, of: change.server)
            hostKeyChange = nil
            failedAttempts = 0
            tryToConnect()
        } catch UnlockError.cancelled {
            // The user changed their mind at the prompt: the sheet stays, and says nothing.
        } catch let error as UnlockError {
            replacementProblem = error.replacementProblem
        } catch {
            replacementProblem = String(describing: error)
        }
    }

    /// The block sheet that showed `change` went away without a replacement. A tab that never
    /// connected closes with it. A change that no longer blocks the tab changes nothing: once its key
    /// was replaced, the connection that follows may be blocked at the next hop at once, and that
    /// block has a sheet of its own.
    public func hostKeyChangeDismissed(_ change: HostKeyChange) {
        guard change == hostKeyChange else { return }
        hostKeyChange = nil
        if connectionCount == 0 {
            state = .closed
            declined(self)
        }
    }

}

/// The tabs' log and signposts (STACK section 6). The signpost interval "Prompt" runs from the
/// moment a connection is asked for, by the tap on Connect or a reconnect, to its shell's first
/// output: README section 16's tap to usable prompt.
enum TabLog {
    static let logger = Logger(subsystem: "ch.shello.Shello", category: "Tabs")
    static let signposter = OSSignposter(logger: logger)
}

/// Whether a later try could succeed where this one failed: the network or the server was away, not
/// the credentials or the host key, at the tab's host or at a jump host on its way.
func isWorthRetrying(_ error: any Error) -> Bool {
    guard let error = ((error as? JumpHostError)?.error ?? error) as? SSHError else { return false }
    switch error {
    case .unreachable, .timedOut, .connectionLost, .closed:
        return true
    case .localNetworkDenied, .authenticationFailed, .partiallyAuthenticated, .signingFailed, .invalidKey,
        .channelRefused, .protocolError, .system:
        return false
    }
}

extension UnlockError {
    /// Why the trusted host key stays, when the user did not authenticate.
    public var replacementProblem: String {
        switch self {
        case .failed: "Shello couldn’t confirm that it’s you. The trusted host key stays."
        case .passcodeNotSet: "Shello can’t ask for your passcode. The trusted host key stays."
        case .cancelled: "Replacing the host key was cancelled."
        case .other(let code): "Shello couldn’t ask you to confirm (error \(code)). The trusted host key stays."
        }
    }
}

/// A host's startup command, as the keys that type it: its lines as written, each ended with
/// Return, as the user would type them (README section 3). A leading space stays, which keeps the
/// command out of bash's history where the user set it up so.
struct StartupCommand: Equatable {
    let bytes: [UInt8]

    /// Nil for a command that is empty or only whitespace.
    init?(_ command: String) {
        var lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }
        bytes = Array(lines.map { $0 + "\r" }.joined().utf8)
    }
}

/// The keys that attach the host's tmux session, or start it (`Tmux.attachCommand(for:)`), as the
/// user would type them, with Return. A space goes first: it keeps the command out of the shell's
/// history where the user set that up, as bash's `HISTCONTROL=ignorespace` and zsh's
/// `HIST_IGNORE_SPACE` do, since it comes with every connection.
struct TmuxAttachKeys: Equatable {
    let bytes: [UInt8]

    /// Nil for a connection that runs a plain shell.
    init?(_ attachment: TmuxAttachment) {
        guard case .attaching(let session, _) = attachment else { return nil }
        bytes = Array((" " + Tmux.attachCommand(for: session) + "\r").utf8)
    }
}

/// The operation did not finish in time.
struct TimedOut: Error {}

/// Runs `operation`, or throws `TimedOut` once `timeout` has passed, which cancels it.
func withTimeout<Result: Sendable>(
    _ timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void,
    _ operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await sleep(timeout)
            throw TimedOut()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
