import ShelloModel
import Synchronization

/// The user's login shell on the server, on a channel with a pseudo-terminal: the stream a terminal
/// attaches to (`TerminalByteStream`, README sections 4 and 5). `SSHConnection.openShell` opens it.
///
/// The terminal sends input and sizes from the main actor; they queue here and go to the server on
/// the connection's queue, in order, without waiting for it. Output is read from the channel only as
/// the terminal asks for it, so a terminal that falls behind stops the reading: the channel's window
/// fills and the server slows down (STACK section 6).
public final class SSHShell: TerminalByteStream, Sendable {
    public let output: Output
    private let connection: SSHConnection
    private let channelID: Int
    private let input: ShellInput

    init(connection: SSHConnection, channelID: Int, input: ShellInput) {
        self.connection = connection
        self.channelID = channelID
        self.input = input
        output = Output(connection: connection, channelID: channelID)
    }

    public func send(_ bytes: [UInt8]) {
        if input.append(bytes) {
            connection.scheduleShellFlush(channelID)
        }
    }

    /// Reports the terminal's grid to the server, as SSH's window-change request.
    public func resize(to size: TerminalSize) {
        if input.setSize(size) {
            connection.scheduleShellFlush(channelID)
        }
    }

    /// Ends the shell's channel. The output ends; the connection stays open.
    public func close() async {
        await connection.closeShell(channelID)
    }

    /// What the shell writes. It finishes when the shell exits or the connection is closed, and
    /// throws `SSHError` when the connection is lost.
    public struct Output: AsyncSequence, Sendable {
        public typealias Element = [UInt8]

        let connection: SSHConnection
        let channelID: Int

        public func makeAsyncIterator() -> Iterator {
            Iterator(connection: connection, channelID: channelID)
        }

        public struct Iterator: AsyncIteratorProtocol {
            let connection: SSHConnection
            let channelID: Int

            /// The next chunk of output. Nil once the shell has ended, the connection was closed, or
            /// the task iterating was cancelled.
            public mutating func next() async throws -> [UInt8]? {
                do {
                    return try await connection.readShell(channelID)
                } catch SSHError.closed {
                    return nil
                } catch is CancellationError {
                    return nil
                }
            }
        }
    }
}

/// What a shell's terminal sent and the last size it reported, until the connection's queue writes
/// them. Only the first of a run of calls schedules that write.
final class ShellInput: Sendable {
    private struct State {
        var bytes: [UInt8] = []
        var size: TerminalSize?
        var isWriteScheduled = false
    }

    private let state = Mutex(State())

    /// Queues `bytes`. Returns whether the caller must schedule the write.
    func append(_ bytes: [UInt8]) -> Bool {
        state.withLock { state in
            state.bytes += bytes
            defer { state.isWriteScheduled = true }
            return !state.isWriteScheduled
        }
    }

    /// Keeps `size` as the size to report. Returns whether the caller must schedule the write.
    func setSize(_ size: TerminalSize) -> Bool {
        state.withLock { state in
            state.size = size
            defer { state.isWriteScheduled = true }
            return !state.isWriteScheduled
        }
    }

    /// Takes what is queued; the next call to `append` or `setSize` schedules a write again.
    func take() -> (bytes: [UInt8], size: TerminalSize?) {
        state.withLock { state in
            defer { state = State() }
            return (state.bytes, state.size)
        }
    }
}
