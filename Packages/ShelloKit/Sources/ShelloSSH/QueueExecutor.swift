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

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = unsafe asUnownedSerialExecutor()
        queue.async {
            unsafe job.runSynchronously(on: executor)
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
