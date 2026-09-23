@testable import Capture
import Dispatch
import Foundation
import Testing

/// `ProcessTapSource` has no test seam onto real Core Audio (a live tap
/// needs a live Mac), so these tests exercise the exact `RebuildCoordinator`
/// instance it delegates its concurrency-sensitive tear-down/build/install
/// sequence to, with a synthetic `build`/`teardown` pair standing in for
/// the tap/aggregate/IOProc set.
@Suite(.serialized)
struct RebuildCoordinatorTests {
    /// Counts how many builds are simultaneously "installed" (between
    /// `build` returning and the matching `teardown` running) — the
    /// concurrent-rebuild-leak defect's own shape: two overlapping
    /// installs would mean two live tap/aggregate/IOProc sets, one of
    /// them never torn down.
    private struct InstallSnapshot {
        let buildCount: Int
        let teardownCount: Int
        let activeCount: Int
        let maxActiveCount: Int
    }

    private final class InstallTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var nextID = 0
        private(set) var buildCount = 0
        private(set) var teardownCount = 0
        private(set) var activeCount = 0
        private(set) var maxActiveCount = 0

        func build(delaySeconds: Double) -> Int {
            let id = lock.withLock {
                nextID += 1
                buildCount += 1
                return nextID
            }
            // Wide enough that a second, truly concurrent build would
            // overlap this one if the two weren't actually serialized.
            Thread.sleep(forTimeInterval: delaySeconds)
            lock.withLock {
                activeCount += 1
                maxActiveCount = max(maxActiveCount, activeCount)
            }
            return id
        }

        func teardown() {
            lock.withLock {
                activeCount -= 1
                teardownCount += 1
            }
        }

        func snapshot() -> InstallSnapshot {
            lock.withLock { InstallSnapshot(buildCount: buildCount, teardownCount: teardownCount, activeCount: activeCount, maxActiveCount: maxActiveCount) }
        }
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func concurrentAsyncRebuildsNeverInstallTwoBuildsAtOnce() async throws {
        let tracker = InstallTracker()
        let coordinator = RebuildCoordinator<Int>(label: "test.rebuild-coordinator.concurrent")

        // Mirrors `ProcessTapSource`'s format-change and default-output
        // listeners firing together for one hardware event: several
        // triggers land at effectively the same moment. `runAsync` itself
        // only enqueues work and returns immediately, so calling it
        // straight from this loop already lands all five requests before
        // the first one's build has had time to finish.
        for _ in 0 ..< 5 {
            coordinator.runAsync(build: { tracker.build(delaySeconds: 0.05) }, teardown: { _ in tracker.teardown() })
        }

        // `buildCount` increments the instant a build starts, well before
        // that build's simulated work finishes — waiting on it alone would
        // race the very install this test means to check. `activeCount`
        // only reaches 1 once a build has fully finished and been
        // installed, so waiting on that instead waits for the whole pass
        // (including any coalesced builds after the first) to settle.
        try await waitUntil(timeout: 3) {
            let snapshot = tracker.snapshot()
            return snapshot.activeCount == 1 && snapshot.teardownCount == snapshot.buildCount - 1
        }

        let result = tracker.snapshot()
        #expect(result.buildCount >= 1)
        #expect(result.maxActiveCount == 1)
        #expect(result.teardownCount == result.buildCount - 1)
        #expect(result.activeCount == 1)

        _ = coordinator.markStopped()
    }

    @Test func syncRebuildSerializesAgainstAnAlreadyRunningAsyncRebuild() async throws {
        let tracker = InstallTracker()
        let coordinator = RebuildCoordinator<Int>(label: "test.rebuild-coordinator.sync-vs-async")

        coordinator.runAsync(build: { tracker.build(delaySeconds: 0.1) }, teardown: { _ in tracker.teardown() })
        try await waitUntil(timeout: 1) { tracker.snapshot().buildCount >= 1 }

        try coordinator.runSync(build: { tracker.build(delaySeconds: 0) }, teardown: { _ in tracker.teardown() })

        let result = tracker.snapshot()
        #expect(result.maxActiveCount == 1)
        #expect(result.teardownCount == result.buildCount - 1)

        _ = coordinator.markStopped()
    }

    @Test func markStoppedTearsDownAResultThatFinishesBuildingAfterItWasCalled() async throws {
        let tracker = InstallTracker()
        let coordinator = RebuildCoordinator<Int>(label: "test.rebuild-coordinator.stop-race")

        coordinator.runAsync(build: { tracker.build(delaySeconds: 0.1) }, teardown: { _ in tracker.teardown() })
        try await waitUntil(timeout: 1) { tracker.snapshot().buildCount >= 1 && tracker.snapshot().activeCount == 0 }

        // `stop()` reaching `markStopped()` before the in-flight build
        // finishes must still not leak that build's result.
        let stoppedHandles = coordinator.markStopped()
        #expect(stoppedHandles == nil)

        try await waitUntil(timeout: 1) { tracker.snapshot().teardownCount >= 1 }
        #expect(tracker.snapshot().activeCount == 0)
        #expect(coordinator.isIdle == false)
    }
}
