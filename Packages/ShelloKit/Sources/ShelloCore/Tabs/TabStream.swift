import ShelloModel
import Synchronization

/// A connection's shell as its tab's terminal sees it: the shell's output, input and size, passed on
/// unchanged, while the tab learns from the output when the shell first printed, when it went quiet,
/// and how it ended. The terminal still reads the output on demand, so a terminal that falls behind
/// still stops the reading (STACK section 6).
final class TabStream<Shell: TerminalByteStream>: TerminalByteStream, Sendable {
    let output: Output
    private let shell: Shell
    let watch: OutputWatch

    init(_ shell: Shell, watch: OutputWatch) {
        self.shell = shell
        self.watch = watch
        output = Output(base: shell.output, watch: watch)
    }

    func send(_ bytes: [UInt8]) {
        shell.send(bytes)
    }

    func resize(to size: TerminalSize) {
        shell.resize(to: size)
    }

    struct Output: AsyncSequence, Sendable {
        typealias Element = [UInt8]

        let base: Shell.Output
        let watch: OutputWatch

        func makeAsyncIterator() -> Iterator {
            Iterator(base: base.makeAsyncIterator(), watch: watch)
        }

        struct Iterator: AsyncIteratorProtocol {
            var base: Shell.Output.AsyncIterator
            let watch: OutputWatch

            mutating func next() async throws -> [UInt8]? {
                try await next(isolation: #isolation)
            }

            /// The shell's next chunk, read where the terminal reads, as `for await` does.
            mutating func next(isolation actor: isolated (any Actor)?) async throws -> [UInt8]? {
                do {
                    let chunk = try await base.next(isolation: actor)
                    if chunk != nil {
                        watch.outputArrived()
                    } else {
                        watch.ended(failure: nil)
                    }
                    return chunk
                } catch {
                    watch.ended(failure: error)
                    throw error
                }
            }
        }
    }
}

/// What a tab learns from its shell's output: when it first came and when it last came, and how the
/// output ended, which `onEnd` hears once.
final class OutputWatch: Sendable {
    private struct State {
        var firstOutput: ContinuousClock.Instant?
        var lastOutput: ContinuousClock.Instant?
        var hasEnded = false
    }

    private let state = Mutex(State())
    private let onFirstOutput: @Sendable () -> Void
    private let onEnd: @Sendable ((any Error)?) -> Void

    /// A watch that calls `onFirstOutput` when the first output arrives, and `onEnd` with the
    /// failure, or nil, when the output ends.
    init(onFirstOutput: @escaping @Sendable () -> Void, onEnd: @escaping @Sendable ((any Error)?) -> Void) {
        self.onFirstOutput = onFirstOutput
        self.onEnd = onEnd
    }

    func outputArrived() {
        let now = ContinuousClock.now
        let isFirst = state.withLock { state in
            defer {
                state.lastOutput = now
                state.firstOutput = state.firstOutput ?? now
            }
            return state.firstOutput == nil
        }
        if isFirst {
            onFirstOutput()
        }
    }

    func ended(failure: (any Error)?) {
        let isFirst = state.withLock { state in
            defer { state.hasEnded = true }
            return !state.hasEnded
        }
        if isFirst {
            onEnd(failure)
        }
    }

    /// Whether output came, and has been quiet for `quiet` since, as a shell's is once it shows its
    /// prompt and waits.
    func isQuiet(for quiet: Duration, at now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { state in
            guard let lastOutput = state.lastOutput else { return false }
            return now - lastOutput >= quiet
        }
    }

    var hasEnded: Bool {
        state.withLock(\.hasEnded)
    }
}
