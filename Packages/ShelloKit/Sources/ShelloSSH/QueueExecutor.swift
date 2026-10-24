import Dispatch

/// The executor of a connection's actor (STACK section 6): the connection's own serial queue, onto
/// which each of the actor's jobs goes as a block, like the queue's other work, the
/// `NWConnection`'s callbacks and the timers.
///
/// `DispatchSerialQueue`'s own executor would do the same with less work, but it hands its jobs to
/// libdispatch past the functions Thread Sanitizer watches. Thread Sanitizer then cannot tell that
/// the jobs and the blocks run one after the other, and reports every variable they share as a
/// race. Libssh is never touched from two threads (ADR 0002), and Thread Sanitizer can show it.
final class QueueExecutor: SerialExecutor {
    let queue: DispatchSerialQueue

    init(queue: DispatchSerialQueue) {
        self.queue = queue
    }

    /// Each block keeps the executor alive until its job has run: a connection's isolated deinit is
    /// a job on it, and releases the executor with the rest of the connection. A jump host's
    /// connection that it releases then deinits too, and the runtime looks at the executor it runs
    /// on, which must still be there.
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = unsafe asUnownedSerialExecutor()
        queue.async { [self] in
            unsafe job.runSynchronously(on: executor)
            withExtendedLifetime(self) {}
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        unsafe UnownedSerialExecutor(ordinary: self)
    }

    /// `assumeIsolated` from the queue's other work, such as the `NWConnection`'s callbacks: they run
    /// on the queue, so they are on the actor.
    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
