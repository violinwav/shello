import Synchronization

/// A tunnel through a connection: a TCP connection that the server makes for Shello to an address
/// and port it reaches, whose bytes travel over an SSH channel (`direct-tcpip`, RFC 4254 section
/// 7.2), as `ssh -W` does. A route's next hop runs over one (README section 3); local forwards and a
/// VNC server's traffic open the same kind (STACK sections 7.1 and 7.9).
/// `SSHConnection.openTunnel(to:port:)` opens it.
///
/// Both directions keep SSH's flow control:
/// - What the far end sends is read from the channel only as fast as `receive()`, or `output`,
///   asks for it. While the reader is behind, the channel's window fills and the far end slows down.
/// - What Shello sends goes into the channel as fast as the far end's window lets it, and waits in
///   the tunnel meanwhile. `drain()` waits for it to go, so that a sender keeps what it holds
///   bounded.
///
/// `send(_:)` and `finish()` return at once and keep the order of their calls; the work happens on
/// the connection's queue, where libssh runs.
public final class SSHTunnel: Sendable {
    private let connection: SSHConnection
    private let channelID: Int
    private let input: TunnelInput

    init(connection: SSHConnection, channelID: Int, input: TunnelInput) {
        self.connection = connection
        self.channelID = channelID
        self.input = input
    }

    /// Sends `bytes` after what was sent before, without waiting.
    public func send(_ bytes: [UInt8]) {
        if input.append(bytes) {
            connection.scheduleTunnelFlush(channelID)
        }
    }

    /// How many of the bytes sent the channel has not taken yet, because the far end's window had
    /// no room for them.
    public var unsentByteCount: Int { input.unsentByteCount }

    /// Returns once the channel has taken every byte sent so far.
    /// - Throws: The connection's `SSHError` if the tunnel or its connection ended first, or
    ///   `CancellationError`.
    public func drain() async throws {
        try await connection.drainTunnel(channelID)
    }

    /// Ends what Shello sends, once what was sent before has gone: the far end reads the end of its
    /// input, as after a TCP half-close, and may still send.
    public func finish() {
        if input.finish() {
            connection.scheduleTunnelFlush(channelID)
        }
    }

    /// The next bytes the far end sent, once there are some, or nil once it ended its side or the
    /// tunnel was closed.
    /// - Throws: The connection's `SSHError` if the connection is lost, or `CancellationError`.
    public func receive() async throws -> [UInt8]? {
        try await connection.receiveTunnel(channelID)
    }

    /// Closes the tunnel at once, in both directions: bytes not sent yet go, and the far end's
    /// output ends.
    public func close() async {
        await connection.closeTunnel(channelID)
    }

    /// What the far end sends, chunk by chunk, read from the channel as it is iterated, as
    /// `receive()` reads it.
    public var output: Output { Output(tunnel: self) }

    public struct Output: AsyncSequence, Sendable {
        public typealias Element = [UInt8]

        let tunnel: SSHTunnel

        public func makeAsyncIterator() -> Iterator {
            Iterator(tunnel: tunnel)
        }

        public struct Iterator: AsyncIteratorProtocol {
            let tunnel: SSHTunnel

            public mutating func next() async throws -> [UInt8]? {
                try await tunnel.receive()
            }
        }
    }
}

/// What a tunnel was given to send, until the connection's queue writes it into the channel, and how
/// much of it the channel has not taken yet. Only the first of a run of calls schedules that write.
final class TunnelInput: Sendable {
    private struct State {
        var bytes: [UInt8] = []
        /// What was given and the channel has not taken yet, what the connection holds included.
        var unsent = 0
        var finishes = false
        var isWriteScheduled = false
    }

    private let state = Mutex(State())

    /// Queues `bytes`. Returns whether the caller must schedule the write.
    func append(_ bytes: [UInt8]) -> Bool {
        state.withLock { state in
            state.bytes += bytes
            state.unsent += bytes.count
            defer { state.isWriteScheduled = true }
            return !state.isWriteScheduled
        }
    }

    /// Asks for the end of the input after the bytes queued. Returns whether the caller must
    /// schedule the write.
    func finish() -> Bool {
        state.withLock { state in
            state.finishes = true
            defer { state.isWriteScheduled = true }
            return !state.isWriteScheduled
        }
    }

    /// Takes the bytes queued, and whether the input ends after them; the next call to `append` or
    /// `finish` schedules a write again.
    func take() -> (bytes: [UInt8], finishes: Bool) {
        state.withLock { state in
            defer {
                state.bytes = []
                state.isWriteScheduled = false
            }
            return (state.bytes, state.finishes)
        }
    }

    /// The channel took `count` more bytes.
    func didSend(_ count: Int) {
        state.withLock { $0.unsent -= count }
    }

    var unsentByteCount: Int { state.withLock(\.unsent) }
}
