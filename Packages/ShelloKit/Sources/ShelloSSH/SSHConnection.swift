import CLibSSH
import Dispatch
import Foundation
import Network
import ShelloModel
import os

/// One SSH connection to a server (GLOSSARY: Connection), the way ADR 0002 and STACK sections 6 and
/// 7.1 lay it out:
/// - Network.framework opens the TCP connection by name, which brings Happy Eyeballs and VPN On
///   Demand. libssh never opens a socket: it gets one end of a socketpair (`SSH_OPTIONS_FD`), and
///   the bridge pumps bytes between the other end and the `NWConnection`.
/// - The connection is an actor whose executor is a serial queue of its own. That queue runs the
///   `NWConnection`'s callbacks, the bridge and every libssh call, so libssh is never touched from
///   two threads, and two connections never share one.
/// - libssh runs non-blocking. A call that has to wait for the server returns at once; the
///   operation suspends until libssh has read something new, and then calls again.
///
/// The steps follow README section 4: `connect()`, which ends with the server's host key for the
/// caller to check before anything about the user is sent; then `authenticate(password:)` or
/// `authenticate(privateKey:passphrase:)`; then `run(_:)` on hidden channels, and `openShell` for a
/// terminal. `close()` ends it all.
public actor SSHConnection {
    /// The server the connection is to.
    public nonisolated let server: Server
    /// The user the connection signs in as.
    public nonisolated let username: String
    /// How long `connect()` waits for the server, from opening the connection to the end of the key
    /// exchange.
    public nonisolated let connectTimeout: Duration
    /// The algorithms the connection offers the server, in their order (README section 14).
    public nonisolated let algorithms: AlgorithmPolicy
    /// The key exchange the connection negotiated with the server, once `connect()` has: the first
    /// of `algorithms`' key exchanges that the server supports too.
    public private(set) var keyExchange: KeyExchange?

    private let queue: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        unsafe queue.asUnownedSerialExecutor()
    }

    // MARK: libssh

    private var session: Handle?
    /// The event that lets the bridge have libssh read and write outside of an operation. It exists
    /// from the first call of `ssh_connect`, which gives the session its poll handle.
    private var event: Handle?
    /// Whether `ssh_connect` has taken over libssh's end of the socketpair.
    private var libsshHasSocket = false
    /// The open channels, by identifier. libssh frees every channel when the session ends, so they
    /// are only reached through this table, which `close()` empties first.
    private var channels: [Int: Handle] = [:]
    private var nextChannelID = 0
    /// The shells among the channels.
    private var shells: [Int: Shell] = [:]

    // MARK: Bridge

    private var sockets: SocketPair?
    private var network: NWConnection?
    private var isNetworkReady = false
    /// Whether a receive on the `NWConnection` is outstanding.
    private var isReceiving = false
    /// Whether the server closed its side of the TCP connection.
    private var serverClosed = false
    /// Whether the bridge ended libssh's input, once the server closed its side.
    private var isLibsshInputClosed = false
    /// The server's bytes that libssh's socket had no room for yet.
    private var inbound: [UInt8] = []
    /// Bytes handed to the `NWConnection` that it has not sent yet. Above `maximumBytesInFlight` the
    /// bridge stops reading libssh's output, libssh's socket fills up, and libssh waits.
    private var bytesInFlight = 0
    private static let maximumBytesInFlight = 1024 * 1024
    private static let chunkSize = 64 * 1024
    private var buffer = [UInt8](repeating: 0, count: SSHConnection.chunkSize)

    // MARK: Waiting

    /// Counts the times libssh read something new or the connection's state changed: what an
    /// operation waits for when libssh tells it to call again later.
    private var progress = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID = 0
    /// Why the connection ended, once it did. Operations that need the server fail with it.
    private var failure: SSHError?
    private var connectDeadline: DispatchWorkItem?

    private static let logger = Logger(subsystem: "ch.shello.Shello", category: "SSH")
    private static let signposter = OSSignposter(logger: logger)

    /// A connection to `server` as `username`, not yet open, which offers the server `algorithms`.
    /// `connectTimeout` bounds `connect()`.
    public init(
        server: Server, username: String, connectTimeout: Duration = Host.defaultConnectTimeout,
        algorithms: AlgorithmPolicy = .standard
    ) {
        self.server = server
        self.username = username
        self.connectTimeout = connectTimeout
        self.algorithms = algorithms
        queue = DispatchSerialQueue(label: "ch.shello.ssh.connection", qos: .userInitiated)
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(queue))
    }

    isolated deinit {
        close()
    }

    /// Marks each connection's queue as its own, so that tests can see where the actor runs.
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    /// The connection's queue, to tell connections' queues apart.
    nonisolated var queueIdentity: ObjectIdentifier { ObjectIdentifier(queue) }

    /// Whether the code calling this runs on the connection's own queue, as all of the actor's
    /// code, libssh's calls included, does.
    var isOnOwnQueue: Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) == queueIdentity
    }

    // MARK: - Connecting

    /// Opens the TCP connection through Network.framework and runs SSH's key exchange, within
    /// `connectTimeout`. Returns the server's host key, which the caller checks before it signs in.
    /// - Throws: `SSHError`, or `CancellationError`.
    public func connect() async throws -> HostKey {
        guard sockets == nil, failure == nil else { throw SSHError.protocolError("the connection was used before") }
        guard LibSSH.isInitialized else { throw SSHError.protocolError("libssh could not be initialised") }
        guard !username.isEmpty else { throw SSHError.protocolError("there is no user to sign in as") }
        guard let port = NWEndpoint.Port(rawValue: server.port), server.port != 0 else {
            throw SSHError.unreachable("port \(server.port) is not a port")
        }
        let interval = Self.signposter.beginInterval("Connect")
        defer { Self.signposter.endInterval("Connect", interval) }

        let sockets = try SocketPair.make()
        self.sockets = sockets
        guard let pointer = unsafe ssh_new() else { throw SSHError.protocolError("libssh could not start a session") }
        let session = unsafe Handle(pointer)
        self.session = session
        try configure(session, socket: sockets.libssh)
        startDeadline()
        startNetwork(port: port)

        try await perform { _ in isNetworkReady ? () : nil }
        try await perform { session in
            let result = unsafe ssh_connect(session.pointer)
            adoptLibsshSocket(session, sockets: sockets)
            switch result {
            case SSH_OK: return ()
            case SSH_AGAIN: return nil
            default: throw failure ?? libsshError(session)
            }
        }
        connectDeadline?.cancel()
        connectDeadline = nil
        keyExchange = negotiatedKeyExchange(session).map(algorithms.keyExchange(named:))
        if let keyExchange {
            let summary = "\(keyExchange.name), \(keyExchange.isPostQuantum ? "post-quantum" : "classical")"
            Self.logger.info("Key exchange: \(summary, privacy: .public); algorithm policy \(self.algorithms.version)")
        }

        var key: OpaquePointer?
        guard unsafe ssh_get_server_publickey(session.pointer, &key) == SSH_OK, let key = unsafe key else {
            throw libsshError(session)
        }
        defer { unsafe ssh_key_free(key) }
        return try unsafe HostKey(libssh: key)
    }

    /// The name of the key exchange libssh negotiated, as libssh reports it.
    private func negotiatedKeyExchange(_ session: Handle) -> String? {
        guard let name = unsafe ssh_get_kex_algo(session.pointer) else { return nil }
        return unsafe String(cString: name)
    }

    /// How the server identified itself once connected, such as `SSH-2.0-OpenSSH_10.3`.
    var serverBanner: String? {
        guard let session, let banner = unsafe ssh_get_serverbanner(session.pointer) else { return nil }
        return unsafe String(cString: banner)
    }

    /// Whether the socket libssh talks on is its end of the socketpair, a Unix socket: libssh opened
    /// no socket of its own.
    var libsshUsesTheSocketpair: Bool {
        guard let session, let sockets, unsafe ssh_get_fd(session.pointer) == sockets.libssh else { return false }
        var address = sockaddr()
        var length = socklen_t(MemoryLayout<sockaddr>.size)
        return unsafe getsockname(sockets.libssh, &address, &length) == 0 && address.sa_family == AF_UNIX
    }

    /// Sets libssh up for the bridge: non-blocking, on its end of the socketpair, and reading no
    /// configuration or `known_hosts` file. Shello keeps its own trust store (STACK section 7.2), and
    /// a configuration file on the device is not the user's. It offers the key exchanges of the
    /// algorithm policy, in its order, and no others.
    private func configure(_ session: Handle, socket: Int32) throws(SSHError) {
        unsafe ssh_set_blocking(session.pointer, 0)
        var socket = socket
        var processConfig = false
        var port = UInt32(server.port)
        let keyExchanges = algorithms.keyExchanges.joined(separator: ",")
        let results = unsafe [
            ssh_options_set(session.pointer, SSH_OPTIONS_FD, &socket),
            ssh_options_set(session.pointer, SSH_OPTIONS_PROCESS_CONFIG, &processConfig),
            ssh_options_set(session.pointer, SSH_OPTIONS_KNOWNHOSTS, "/dev/null"),
            ssh_options_set(session.pointer, SSH_OPTIONS_GLOBAL_KNOWNHOSTS, "/dev/null"),
            ssh_options_set(session.pointer, SSH_OPTIONS_USER, username),
            ssh_options_set(session.pointer, SSH_OPTIONS_PORT, &port),
            ssh_options_set(session.pointer, SSH_OPTIONS_KEY_EXCHANGE, keyExchanges),
        ]
        guard results.allSatisfy({ $0 == SSH_OK }) else { throw libsshError(session) }
        // Only for libssh's messages: it never connects by itself. libssh refuses some addresses
        // that Network.framework takes, such as an IPv6 address with a zone.
        if unsafe ssh_options_set(session.pointer, SSH_OPTIONS_HOST, server.address) != SSH_OK {
            Self.logger.debug("libssh did not take the server's address")
        }
    }

    /// Called after each `ssh_connect`. libssh makes its socket blocking once it counts as
    /// connected, which would let one of its writes wait for the bridge, which runs on the same
    /// queue: the socket is made non-blocking again. libssh only writes after `poll` reported room,
    /// and handles the short writes this allows. The first call also gives the session the poll
    /// handle that the bridge's event runs.
    private func adoptLibsshSocket(_ session: Handle, sockets: SocketPair) {
        libsshHasSocket = true
        SocketPair.setNonBlocking(sockets.libssh)
        guard event == nil, let pointer = unsafe ssh_event_new() else { return }
        if unsafe ssh_event_add_session(pointer, session.pointer) == SSH_OK {
            event = unsafe Handle(pointer)
        } else {
            unsafe ssh_event_free(pointer)
        }
    }

    private func startDeadline() {
        let deadline = DispatchWorkItem { [weak self] in
            self?.assumeIsolated { connection in
                if connection.connectDeadline != nil {
                    connection.fail(.timedOut)
                }
            }
        }
        connectDeadline = deadline
        let (seconds, attoseconds) = connectTimeout.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds), execute: deadline)
    }

    // MARK: - Signing in

    /// Signs in with `password`, which libssh reads in place (README section 13).
    /// - Throws: `SSHError.authenticationFailed` if the server refuses it, another `SSHError`, or
    ///   `CancellationError`.
    public func authenticate(password: some SecretBytes) async throws {
        let interval = Self.signposter.beginInterval("Authenticate")
        defer { Self.signposter.endInterval("Authenticate", interval) }
        try await authenticate { session in
            unsafe password.withUnsafeBytes { bytes in
                unsafe ssh_userauth_password(
                    session.pointer, nil, bytes.baseAddress?.assumingMemoryBound(to: CChar.self))
            }
        }
    }

    /// Signs in with an imported private key (README section 13): its text, in OpenSSH's or PEM's
    /// format, and its passphrase if it is encrypted. libssh reads the key on the connection's queue
    /// and frees it once the server has answered.
    /// - Throws: `SSHError.invalidKey` if the key cannot be read, `SSHError.authenticationFailed` if
    ///   the server refuses it, another `SSHError`, or `CancellationError`.
    public func authenticate(privateKey: some SecretBytes, passphrase: (any SecretBytes)? = nil) async throws {
        let interval = Self.signposter.beginInterval("Authenticate")
        defer { Self.signposter.endInterval("Authenticate", interval) }
        let key = try ImportedKey(text: privateKey, passphrase: passphrase)
        try await authenticate { session in unsafe ssh_userauth_publickey(session.pointer, nil, key.key.pointer) }
    }

    private func authenticate(_ attempt: (Handle) -> Int32) async throws {
        try await perform { session in
            switch attempt(session) {
            case SSH_AUTH_SUCCESS.rawValue: return ()
            case SSH_AUTH_AGAIN.rawValue: return nil
            // A partial success asks for another method as well: keyboard-interactive comes in #27.
            case SSH_AUTH_DENIED.rawValue, SSH_AUTH_PARTIAL.rawValue: throw SSHError.authenticationFailed
            default: throw failure ?? libsshError(session)
            }
        }
    }

    // MARK: - Commands

    /// Runs `command` on a hidden channel (GLOSSARY) and returns what it printed and how it exited.
    /// The output is kept in memory whole, so this is for commands that print little.
    /// - Throws: `SSHError`, or `CancellationError`.
    public func run(_ command: String) async throws -> SSHCommandResult {
        let id = try await openSessionChannel()
        defer { freeChannel(id) }
        try await perform { session in
            let channel = try channel(id)
            return try requestDone(unsafe ssh_channel_request_exec(channel.pointer, command), session)
        }

        var output: [UInt8] = []
        var errorOutput: [UInt8] = []
        var ended = false
        while !ended {
            try await perform { _ in
                let channel = try channel(id)
                let standard = try readChunk(channel, isStandardError: false)
                let error = try readChunk(channel, isStandardError: true)
                if case .bytes(let bytes) = standard { output += bytes }
                if case .bytes(let bytes) = error { errorOutput += bytes }
                switch (standard, error) {
                case (.end, .end):
                    ended = true
                    return ()
                case (.bytes, _), (_, .bytes): return ()
                default: return nil
                }
            }
        }
        let exitStatus: Int? = try await perform { session in
            let channel = try channel(id)
            var code: UInt32 = 0
            var signal: UnsafeMutablePointer<CChar>?
            switch unsafe ssh_channel_get_exit_state(channel.pointer, &code, &signal, nil) {
            case SSH_OK:
                // A command that a signal ended has no exit status.
                let wasSignalled = unsafe signal != nil
                unsafe free(signal)
                return .some(wasSignalled ? nil : Int(code))
            // The server closed the channel without saying how the command ended.
            case SSH_AGAIN: return unsafe ssh_channel_is_closed(channel.pointer) != 0 ? .some(nil) : nil
            default: throw failure ?? libsshError(session)
            }
        }
        return SSHCommandResult(output: output, errorOutput: errorOutput, exitStatus: exitStatus)
    }

    // MARK: - Shells

    /// Opens a channel with a pseudo-terminal of `terminalType` and `size`, starts the user's login
    /// shell on it, and returns it as the stream a terminal attaches to (README sections 4 and 5).
    /// libssh's pseudo-terminal request carries no pixel size, so the pixels in `size` are not sent.
    /// - Throws: `SSHError`, or `CancellationError`.
    public func openShell(terminalType: String, size: TerminalSize) async throws -> SSHShell {
        let id = try await openSessionChannel()
        do {
            try await perform { session in
                let channel = try channel(id)
                let result = unsafe ssh_channel_request_pty_size(
                    channel.pointer, terminalType, Int32(clamping: size.columns), Int32(clamping: size.rows))
                return try requestDone(result, session)
            }
            try await perform { session in
                let channel = try channel(id)
                return try requestDone(unsafe ssh_channel_request_shell(channel.pointer), session)
            }
        } catch {
            freeChannel(id)
            throw error
        }
        let input = ShellInput()
        shells[id] = Shell(input: input, size: size)
        return SSHShell(connection: self, channelID: id, input: input)
    }

    /// The shell's next output, or nil once the shell or the connection has ended.
    func readShell(_ id: Int) async throws -> [UInt8]? {
        try await perform { _ -> [UInt8]?? in
            guard let channel = channels[id] else { return .some(nil) }
            // A pseudo-terminal sends everything on the standard stream; the other one is read too,
            // for a server that uses it anyway.
            for isStandardError in [false, true] {
                switch try readChunk(channel, isStandardError: isStandardError) {
                case .bytes(let bytes): return .some(bytes)
                case .end: return .some(nil)
                case .empty: continue
                }
            }
            return nil
        }
    }

    /// Writes what the shell's terminal sent and reports a new size, as far as the server's window
    /// lets it. What is left waits until libssh reads more, such as the server's window adjustment.
    func flushShell(_ id: Int) {
        guard var shell = shells[id], let channel = channels[id] else { return }
        let (bytes, size) = shell.input.take()
        shell.backlog += bytes
        if let size, size != shell.size {
            shell.pendingSize = size
        }
        if let size = shell.pendingSize {
            let result = unsafe ssh_channel_change_pty_size(
                channel.pointer, Int32(clamping: size.columns), Int32(clamping: size.rows))
            if result == SSH_OK {
                shell.size = size
                shell.pendingSize = nil
            }
        }
        while !shell.backlog.isEmpty {
            let written = unsafe shell.backlog.withUnsafeBytes { bytes in
                unsafe ssh_channel_write(channel.pointer, bytes.baseAddress, UInt32(clamping: bytes.count))
            }
            guard written > 0 else { break }
            shell.backlog.removeFirst(Int(written))
        }
        shells[id] = shell
        pump()
    }

    /// Schedules `flushShell(_:)` on the connection's queue, after the work queued before it, so
    /// that input keeps its order.
    nonisolated func scheduleShellFlush(_ id: Int) {
        queue.async { [weak self] in
            self?.assumeIsolated { $0.flushShell(id) }
        }
    }

    /// Ends the shell: frees its channel, which libssh closes. Its output ends.
    func closeShell(_ id: Int) {
        shells[id] = nil
        freeChannel(id)
        progress += 1
        wakeWaiters()
    }

    private struct Shell {
        let input: ShellInput
        /// The size the server knows.
        var size: TerminalSize
        /// A new size the server has not taken yet.
        var pendingSize: TerminalSize?
        /// Input the server's window had no room for yet.
        var backlog: [UInt8] = []

        init(input: ShellInput, size: TerminalSize) {
            self.input = input
            self.size = size
        }

        var hasPendingInput: Bool { !backlog.isEmpty || pendingSize != nil }
    }

    // MARK: - Channels

    private func openSessionChannel() async throws -> Int {
        guard let session, failure == nil else { throw failure ?? SSHError.closed }
        guard let pointer = unsafe ssh_channel_new(session.pointer) else { throw libsshError(session) }
        let id = nextChannelID
        nextChannelID += 1
        channels[id] = unsafe Handle(pointer)
        do {
            try await perform { session in
                let channel = try self.channel(id)
                switch unsafe ssh_channel_open_session(channel.pointer) {
                case SSH_OK: return ()
                case SSH_AGAIN: return nil
                default: throw failure ?? SSHError.channelRefused(libsshMessage(session))
                }
            }
        } catch {
            freeChannel(id)
            throw error
        }
        return id
    }

    private func channel(_ id: Int) throws(SSHError) -> Handle {
        guard let channel = channels[id] else { throw failure ?? .closed }
        return channel
    }

    /// Frees a channel the connection no longer needs; libssh closes it first if it is open.
    private func freeChannel(_ id: Int) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        unsafe ssh_channel_free(channel.pointer)
        pump()
    }

    /// Whether a channel request that wants a reply is done: nil to call again, or an error.
    private func requestDone(_ result: Int32, _ session: Handle) throws -> Void? {
        switch result {
        case SSH_OK: return ()
        case SSH_AGAIN: return nil
        default: throw failure ?? SSHError.channelRefused(libsshMessage(session))
        }
    }

    private enum Chunk {
        case bytes([UInt8])
        case empty
        case end
    }

    /// What libssh holds of one of the channel's streams, without waiting.
    private func readChunk(_ channel: Handle, isStandardError: Bool) throws -> Chunk {
        let count = unsafe buffer.withUnsafeMutableBytes { buffer in
            unsafe ssh_channel_read_nonblocking(
                channel.pointer, buffer.baseAddress, UInt32(buffer.count), isStandardError ? 1 : 0)
        }
        switch count {
        case 1...: return .bytes(Array(buffer.prefix(Int(count))))
        case 0: return .empty
        case SSH_EOF: return .end
        default: throw failure ?? libsshError(session)
        }
    }

    // MARK: - Closing

    /// Closes the connection: tells the server, frees libssh's session and channels, and closes the
    /// sockets. Operations still waiting fail with `SSHError.closed`; a shell's output ends.
    /// Closing again does nothing.
    public func close() {
        connectDeadline?.cancel()
        connectDeadline = nil
        channels.removeAll()
        shells.removeAll()
        var closesLibsshSocket = true
        if let session {
            if let event {
                unsafe ssh_event_remove_session(event.pointer, session.pointer)
                unsafe ssh_event_free(event.pointer)
                self.event = nil
            }
            // libssh closes its end of the socketpair itself only if writing to it failed, and then
            // forgets it.
            if libsshHasSocket {
                closesLibsshSocket = unsafe ssh_get_fd(session.pointer) == sockets?.libssh
            }
            unsafe ssh_disconnect(session.pointer)
            _ = sendLibsshOutput()
            unsafe ssh_free(session.pointer)
            self.session = nil
        }
        if let sockets {
            if closesLibsshSocket {
                Darwin.close(sockets.libssh)
            }
            Darwin.close(sockets.bridge)
            self.sockets = nil
        }
        if let network {
            network.cancel()
            self.network = nil
        }
        if failure == nil {
            failure = .closed
        }
        progress += 1
        wakeWaiters()
    }

    // MARK: - Operations

    /// Calls `attempt`, which makes one non-blocking libssh call, until it returns a result. After
    /// each call the bridge moves what libssh wrote; when the call has to wait for the server, the
    /// operation waits until libssh has read something new.
    private func perform<Result>(_ attempt: (Handle) throws -> Result?) async throws -> Result {
        while true {
            guard let session else { throw failure ?? SSHError.closed }
            let seen = progress
            let unread = unreadByLibssh
            let result = try attempt(session)
            if unreadByLibssh < unread {
                progress += 1
            }
            pump()
            if let result { return result }
            if let failure { throw failure }
            try Task.checkCancellation()
            if progress == seen {
                await waitForProgress(since: seen)
            } else {
                // libssh read something, which may be what other operations wait for.
                wakeWaiters()
            }
        }
    }

    /// The bytes waiting in libssh's socket.
    private var unreadByLibssh: Int {
        sockets.map { SocketPair.unreadByteCount($0.libssh) } ?? 0
    }

    /// Returns once `progress` has moved on from `seen`, the connection failed or closed, or the
    /// task was cancelled.
    private func waitForProgress(since seen: Int) async {
        guard progress == seen, failure == nil, !Task.isCancelled else { return }
        let id = nextWaiterID
        nextWaiterID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            queue.async { [weak self] in
                self?.assumeIsolated { $0.waiters.removeValue(forKey: id)?.resume() }
            }
        }
    }

    private func wakeWaiters() {
        let waiting = waiters.values
        waiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
    }

    /// Ends the connection for `error`: operations waiting fail with it, and libssh reads the end of
    /// its input.
    private func fail(_ error: SSHError) {
        guard failure == nil else { return }
        Self.logger.notice("Connection ended: \(error.description)")
        failure = error
        network?.cancel()
        endLibsshInput()
        progress += 1
        wakeWaiters()
    }

    // MARK: - Bridge

    private func startNetwork(port: NWEndpoint.Port) {
        let tcp = NWProtocolTCP.Options()
        // Every keystroke goes out at once (README section 16: keystroke to network under 10 ms).
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(connectTimeout.components.seconds))
        let network = NWConnection(
            host: NWEndpoint.Host(server.address), port: port, using: NWParameters(tls: nil, tcp: tcp))
        network.stateUpdateHandler = { [weak self] state in
            self?.assumeIsolated { $0.networkStateChanged(state) }
        }
        self.network = network
        network.start(queue: queue)
    }

    private func networkStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isNetworkReady = true
            progress += 1
            wakeWaiters()
            pump()
        case .waiting(let error):
            // Refused, no route or no network. Waiting for a better path belongs to reconnecting
            // (#28); a first connection fails at once.
            if !isNetworkReady { fail(.network(error, ready: false)) }
        case .failed(let error):
            fail(.network(error, ready: isNetworkReady))
        case .cancelled:
            fail(.closed)
        default:
            break
        }
    }

    /// Moves bytes until nothing moves: libssh's output to the server, the server's bytes to
    /// libssh, and libssh's reading and writing in between. Wakes the operations waiting when libssh
    /// read something.
    private func pump() {
        guard sockets != nil else { return }
        var libsshRead = false
        for _ in 0..<64 {
            let sent = sendLibsshOutput()
            let fed = feedLibssh()
            let read = runLibssh()
            libsshRead = libsshRead || read
            if !(sent || fed || read) { break }
        }
        // The server closed the connection, and libssh has read everything before that.
        if serverClosed, inbound.isEmpty, !isLibsshInputClosed {
            endLibsshInput()
        }
        if libsshRead {
            progress += 1
            wakeWaiters()
            for (id, shell) in shells where shell.hasPendingInput {
                scheduleShellFlush(id)
            }
        }
        receive()
    }

    /// Reads what libssh wrote to its socket and hands it to the `NWConnection`. Returns whether
    /// there was anything.
    private func sendLibsshOutput() -> Bool {
        guard let sockets, let network, isNetworkReady, bytesInFlight < Self.maximumBytesInFlight else {
            return false
        }
        let count = unsafe buffer.withUnsafeMutableBytes { buffer in
            unsafe Darwin.read(sockets.bridge, buffer.baseAddress, buffer.count)
        }
        guard count > 0 else { return false }
        bytesInFlight += count
        network.send(
            content: Data(buffer.prefix(count)),
            completion: .contentProcessed { [weak self] error in
                self?.assumeIsolated { connection in
                    connection.bytesInFlight -= count
                    if let error {
                        connection.fail(.network(error, ready: true))
                    } else {
                        connection.pump()
                    }
                }
            })
        return true
    }

    /// Writes the server's bytes that libssh's socket had no room for. Returns whether it wrote any.
    private func feedLibssh() -> Bool {
        guard let sockets, !inbound.isEmpty else { return false }
        let written = unsafe inbound.withUnsafeBytes { bytes in
            unsafe Darwin.write(sockets.bridge, bytes.baseAddress, bytes.count)
        }
        guard written > 0 else {
            if written < 0, errno != EAGAIN {
                fail(.system("Could not pass the server’s data on", errno))
            }
            return false
        }
        inbound.removeFirst(written)
        return true
    }

    /// Lets libssh read what the bridge wrote to its socket and write what it queued, outside of any
    /// operation, so that a channel nobody reads never holds up the others. Returns whether libssh
    /// read anything.
    private func runLibssh() -> Bool {
        guard let session, let event, let sockets else { return false }
        var read = false
        for _ in 0..<64 {
            let unread = SocketPair.unreadByteCount(sockets.libssh)
            let status = unsafe ssh_get_status(session.pointer)
            guard unread > 0 || status & SSH_WRITE_PENDING != 0 else { break }
            let result = unsafe ssh_event_dopoll(event.pointer, 0)
            let consumed = SocketPair.unreadByteCount(sockets.libssh) < unread
            read = read || consumed
            if result == SSH_ERROR {
                read = true
                break
            }
            if !consumed, result != SSH_OK { break }
        }
        return read
    }

    /// Asks the `NWConnection` for the server's next bytes, once libssh's socket took the last ones.
    private func receive() {
        guard let network, isNetworkReady, !isReceiving, !serverClosed, inbound.isEmpty, failure == nil else {
            return
        }
        isReceiving = true
        network.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) {
            [weak self] content, _, isComplete, error in
            self?.assumeIsolated { connection in
                connection.isReceiving = false
                if let content { connection.inbound += content }
                if isComplete { connection.serverClosed = true }
                if let error {
                    connection.fail(.network(error, ready: true))
                } else {
                    connection.pump()
                }
            }
        }
    }

    /// Shuts the bridge's end of the socketpair for writing: libssh reads the end of its input and
    /// ends its session. Once the server closed the connection, the connection has ended.
    private func endLibsshInput() {
        guard let sockets, !isLibsshInputClosed else { return }
        isLibsshInputClosed = true
        shutdown(sockets.bridge, SHUT_WR)
        if serverClosed {
            fail(.connectionLost("the server closed the connection"))
        }
    }

    // MARK: - Errors

    private func libsshError(_ session: Handle?) -> SSHError {
        .protocolError(libsshMessage(session))
    }

    private func libsshMessage(_ session: Handle?) -> String {
        guard let session, let message = unsafe ssh_get_error(UnsafeMutableRawPointer(session.pointer)) else {
            return "unknown error"
        }
        let text = unsafe String(cString: message)
        return text.isEmpty ? "unknown error" : text
    }
}

/// What a command printed, and how it exited.
public struct SSHCommandResult: Hashable, Sendable {
    /// What the command wrote to its standard output.
    public var output: [UInt8]
    /// What the command wrote to its standard error.
    public var errorOutput: [UInt8]
    /// The command's exit status, or nil if the server did not say, as when a signal ended it.
    public var exitStatus: Int?

    public init(output: [UInt8], errorOutput: [UInt8], exitStatus: Int?) {
        self.output = output
        self.errorOutput = errorOutput
        self.exitStatus = exitStatus
    }
}
