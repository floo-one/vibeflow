import Foundation

/// Runs blocking work (such as an NSPasteboard read that may wait on a lazy provider) on a
/// GCD thread and returns its result, or nil once `deadline` passes on `clock`, whichever
/// comes first. Unlike `withTimeout`, the caller is released at the deadline even though
/// the blocking call itself cannot be interrupted; the work finishes in the background and
/// its late result is dropped.
///
/// Why not `withTimeout { await Task.detached { ... }.value }`: a task group cannot return
/// until every child finishes, and awaiting a detached task's value ignores cancellation,
/// so that pattern waits for the blocking call no matter what the deadline says.
public func runBlocking<T: Sendable>(
    within deadline: Duration,
    clock: any SessionClock,
    _ work: @escaping @Sendable () -> T
) async -> T? {
    let gate = ResumeOnce<T?>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.install(continuation)
            gate.setTimer(Task {
                try? await clock.sleep(for: deadline)
                gate.resume(nil)
            })
            DispatchQueue.global(qos: .userInitiated).async {
                gate.resume(work())
            }
        }
    } onCancel: {
        gate.resume(nil)
    }
}

/// Resumes a continuation exactly once, from whichever side gets there first, and cancels
/// the deadline timer so no sleeper lingers on the clock.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var timer: Task<Void, Never>?
    private var pending: Value?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if finished, let value = pending {
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTimer(_ task: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
            return
        }
        timer = task
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        if continuation == nil { pending = value }
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}
