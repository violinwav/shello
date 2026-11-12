import ShelloModel
import Synchronization

/// The terminal demo under Settings, Diagnostics: a byte stream with a stand-in for a shell on the
/// other end, which runs on the device and never touches the network (GLOSSARY, Terminal demo). It
/// shows a prompt, echoes what the user types and runs the demo's commands, which print the screens
/// that exercise colours, attributes, Unicode and the alternate screen, and the 10 MB output test.
///
/// Its output is made as the terminal asks for it, a chunk at a time, the way an SSH channel is
/// read: the output test never runs ahead of the terminal, and the user's input, checked before
/// each chunk, is echoed at once even in the middle of the test.
nonisolated public final class TerminalDemo: TerminalByteStream {
    public let output: Output
    private let inbox: Inbox

    public init() {
        inbox = Inbox()
        output = Output(inbox: inbox)
    }

    public func send(_ bytes: [UInt8]) {
        inbox.post(.input(bytes))
    }

    public func resize(to size: TerminalSize) {
        inbox.post(.resize(size))
    }

    /// Runs one of the demo's commands as if the user typed it.
    public func run(_ command: DemoCommand) {
        inbox.post(.command(command))
    }

    /// The demo's output. It never ends on its own.
    nonisolated public struct Output: AsyncSequence, Sendable {
        public typealias Element = [UInt8]
        public typealias Failure = Never

        fileprivate let inbox: Inbox

        public func makeAsyncIterator() -> Iterator {
            Iterator(inbox: inbox)
        }

        nonisolated public struct Iterator: AsyncIteratorProtocol {
            fileprivate let inbox: Inbox
            private var shell = DemoShell()

            fileprivate init(inbox: Inbox) {
                self.inbox = inbox
            }

            /// The next chunk: echo and the output of commands first, then the output test's next
            /// chunk, or else waits for the user. Nil once the task iterating it is cancelled.
            public mutating func next() async -> [UInt8]? {
                while !Task.isCancelled {
                    for event in inbox.take() {
                        shell.handle(event)
                    }
                    if let output = shell.takeOutput() ?? shell.nextFloodChunk() {
                        return output
                    }
                    await inbox.wait()
                }
                return nil
            }
        }
    }
}

/// The events for the demo's shell, in the order they were posted. The terminal posts them on the
/// main actor; the output's iterator takes them on its own task.
nonisolated private final class Inbox: Sendable {
    private struct State {
        var events: [DemoShell.Event] = []
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func post(_ event: DemoShell.Event) {
        let waiter = state.withLock { state in
            state.events.append(event)
            return state.waiter.take()
        }
        waiter?.resume()
    }

    func take() -> [DemoShell.Event] {
        state.withLock { state in
            defer { state.events.removeAll() }
            return state.events
        }
    }

    /// Returns once an event has been posted, at once if one is waiting, or once the task is
    /// cancelled.
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state in
                    guard state.events.isEmpty, !Task.isCancelled else { return true }
                    state.waiter = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            state.withLock { $0.waiter.take() }?.resume()
        }
    }
}
