import Foundation
@testable import Orchestrator
import os

/// Collects the exits a `terminationHandler` reports, from whatever queue
/// Foundation calls it on.
final class WorkerExitCollector: Sendable {
    private let recorded = OSAllocatedUnfairLock<[WorkerExit]>(initialState: [])

    var exits: [WorkerExit] {
        recorded.withLock { $0 }
    }

    /// Passed as an `onExit`/`onWorkerExit` closure.
    @Sendable
    func add(_ exit: WorkerExit) {
        recorded.withLock { $0.append(exit) }
    }
}

/// Polls `condition` until it holds. Exists because a subprocess's exit
/// arrives asynchronously, on a queue the test does not control; the deadline
/// makes a handler that never fires fail the test instead of hanging it.
func waitUntil(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
