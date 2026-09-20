import Foundation

struct DeadlineExceeded: Error {}

/// Runs `work` and throws `DeadlineExceeded` if it has not finished within
/// `seconds`. The caller is released at the deadline even when `work` ignores
/// cancellation: a structured task group would wait for it, and the whole
/// point of the budget is to stop waiting on a reviewer that hangs.
func withDeadline<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = DeadlineGate<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            let worker = Task {
                do {
                    try await gate.finish(.success(work()))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                gate.finish(.failure(DeadlineExceeded()))
            }
            gate.onFinish {
                worker.cancel()
                timer.cancel()
            }
        }
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

/// Resumes its continuation exactly once, whichever of the worker, the timer
/// and outer cancellation gets there first.
private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var done = false
    private var cleanup: (@Sendable () -> Void)?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let pending {
            continuation.resume(with: pending)
        } else {
            self.continuation = continuation
        }
    }

    func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
        lock.lock()
        if done {
            lock.unlock()
            cleanup()
        } else {
            self.cleanup = cleanup
            lock.unlock()
        }
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pending = result
        }
        let cleanup = cleanup
        lock.unlock()
        continuation?.resume(with: result)
        cleanup?()
    }
}
