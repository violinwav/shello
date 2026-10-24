import Dispatch
import Foundation
import Synchronization

/// One client of the SSH agent, on one socket (draft-ietf-sshm-ssh-agent section 3): it reads the
/// client's requests as they arrive, answers them one at a time, in their order, and writes each
/// reply. It runs on a serial queue of its own: libssh waits for each reply on its connection's
/// queue, so it must be answered from elsewhere.
///
/// The socket is closed once the client closes its end, sends what is not a message, or `close()`
/// is called. Closing also cancels the request being answered, such as a signature that waits for
/// Face ID, whose prompt then goes: the client reads the end of the socket at once, and never waits
/// for the user.
final class SSHAgentListener: Sendable {
    private let socket: Int32
    private let queue = DispatchQueue(label: "ch.shello.ssh-agent", qos: .userInitiated)
    private let answer: @Sendable ([UInt8]) async -> [UInt8]
    private let state = Mutex(State())

    private struct State {
        var frames = SSHAgentFrames()
        /// Whether a request is being answered: the next waits for its reply.
        var isAnswering = false
        /// The answer being worked out, which closing cancels.
        var answering: Task<Void, Never>?
        var source: (any DispatchSourceRead)?
        var isClosed = false
    }

    /// The most the client may send ahead of the replies: a request at its longest, and then some.
    private static let maximumPending = 2 * Int(SSHAgentFrames.maximumLength)

    /// A listener on `socket`, the agent's end of a connected pair, which it owns and closes. It
    /// answers each request's contents with what `answer` returns.
    init(socket: Int32, answer: @escaping @Sendable ([UInt8]) async -> [UInt8]) {
        self.socket = socket
        self.answer = answer
    }

    /// Starts reading the client's requests.
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        // Runs on the queue once the source is cancelled, after its last event: nothing reads or
        // writes the socket any more.
        let socket = socket
        source.setCancelHandler { Darwin.close(socket) }
        let started = state.withLock { state in
            guard !state.isClosed else { return false }
            state.source = source
            return true
        }
        if started {
            source.activate()
        } else {
            Darwin.close(socket)
        }
    }

    /// Stops answering, cancels the answer being worked out, and closes the socket. Safe from any
    /// thread, more than once.
    func close() {
        let (source, answering) = state.withLock { state -> ((any DispatchSourceRead)?, Task<Void, Never>?) in
            guard !state.isClosed else { return (nil, nil) }
            state.isClosed = true
            defer {
                state.source = nil
                state.answering = nil
            }
            return (state.source, state.answering)
        }
        source?.cancel()
        answering?.cancel()
    }

    // MARK: - On the queue

    /// Reads what the client sent, then answers the next request if none is being answered.
    private func readAvailable() {
        guard !state.withLock(\.isClosed) else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var clientIsGone = false
        while true {
            let count = unsafe buffer.withUnsafeMutableBytes { bytes in
                unsafe read(socket, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let pending = state.withLock { state in
                    state.frames.append(buffer.prefix(count))
                    return state.frames.pendingCount
                }
                if pending > Self.maximumPending {
                    clientIsGone = true
                    break
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                // The end of the client's requests, or an error other than having read all there is.
                clientIsGone = count == 0 || errno != EAGAIN
                break
            }
        }
        if clientIsGone {
            close()
        } else {
            answerNext()
        }
    }

    /// Answers the next complete request, unless one is being answered.
    private func answerNext() {
        enum Next {
            case wait
            case answer([UInt8])
            case close
        }
        let next = state.withLock { state -> Next in
            guard !state.isAnswering, !state.isClosed else { return .wait }
            do {
                guard let message = try state.frames.next() else { return .wait }
                state.isAnswering = true
                return .answer(message)
            } catch {
                return .close
            }
        }
        switch next {
        case .wait:
            break
        case .close:
            close()
        case .answer(let message):
            let answer = answer
            let task = Task {
                let reply = await answer(message)
                self.queue.async { self.send(reply) }
            }
            let isClosed = state.withLock { state in
                state.answering = task
                return state.isClosed
            }
            if isClosed {
                task.cancel()
            }
        }
    }

    /// Writes `reply` to the client, then answers the next request.
    private func send(_ reply: [UInt8]) {
        guard !state.withLock(\.isClosed) else { return }
        let bytes = SSHAgentFrames.frame(reply)
        var written = 0
        while written < bytes.count {
            let count = unsafe bytes[written...].withUnsafeBytes { bytes in
                unsafe write(socket, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                written += count
            } else if count < 0, errno == EINTR || (errno == EAGAIN && waitUntilWritable()) {
                continue
            } else {
                close()
                return
            }
        }
        state.withLock { $0.isAnswering = false }
        answerNext()
    }

    /// Waits up to a second for room in the socket. Replies are short, and the client reads each
    /// one before it asks again, so there is room unless the client is gone.
    private func waitUntilWritable() -> Bool {
        var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        return unsafe poll(&descriptor, 1, 1000) == 1
    }

    // MARK: - Sockets

    /// A connected pair of Unix stream sockets, for the agent and its client: both non-blocking, and
    /// neither raises SIGPIPE when the other end is gone, which would end the app.
    static func socketPair() throws(SSHAgentError) -> (agent: Int32, client: Int32) {
        var ends: [Int32] = [-1, -1]
        guard unsafe socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else { throw .socket(errno) }
        for end in ends {
            var on: Int32 = 1
            let flags = fcntl(end, F_GETFL)
            let isSetUp =
                unsafe setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
                && flags >= 0 && fcntl(end, F_SETFL, flags | O_NONBLOCK) == 0
            guard isSetUp else {
                let code = errno
                for end in ends { Darwin.close(end) }
                throw .socket(code)
            }
        }
        return (ends[0], ends[1])
    }
}
