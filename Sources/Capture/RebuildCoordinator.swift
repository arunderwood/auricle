import Dispatch
import Foundation

/// Serializes a tear-down/build/install sequence so two triggers arriving
/// close together — `ProcessTapSource`'s format-change and default-output
/// listeners both firing for one hardware event (e.g. an AirPods profile
/// switch) — always run one after the other rather than each independently
/// tearing down and building, which is what leaks the loser's handles.
/// Generic over `Handles` and free of any Core Audio call so this
/// serialization contract is directly testable without a live tap.
final class RebuildCoordinator<Handles>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var current: Handles?
    private var isStopped = false
    /// Guards `runAsync` against enqueueing more than one pending block at
    /// a time: set when a block is enqueued, cleared right as that block
    /// starts running. A call that arrives while it's set just returns,
    /// since the one already enqueued will still run and see whatever
    /// triggered the second call.
    private var pendingAsyncRequest = false

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    /// `true` once nothing is installed and this coordinator hasn't been
    /// stopped — what a caller checks before attempting its first build,
    /// since starting a second time on an already-running (or
    /// already-stopped) instance is a caller error.
    var isIdle: Bool {
        lock.withLock { current == nil && !isStopped }
    }

    /// Marks this coordinator stopped and removes whatever was installed,
    /// handing it back for the caller to tear down itself. A rebuild
    /// already running on `queue` when this is called still finishes its
    /// own build, but finds `isStopped` set at its own install step and
    /// tears its freshly built result back down instead of installing it.
    func markStopped() -> Handles? {
        lock.withLock {
            let value = current
            current = nil
            isStopped = true
            return value
        }
    }

    /// The synchronous entry point: runs on `queue`, serializing against
    /// any `runAsync` pass already in flight rather than racing it.
    func runSync(build: () throws -> Handles, teardown: (Handles) -> Void) throws {
        try queue.sync { try rebuildOnQueue(build: build, teardown: teardown) }
    }

    /// The trigger-driven entry point: dispatches onto `queue` rather than
    /// running inline on whatever thread called this (avoiding reentering
    /// a callback that's mid-notification), and coalesces a burst of
    /// near-simultaneous calls behind `pendingAsyncRequest` into one pass.
    func runAsync(build: @escaping () throws -> Handles, teardown: @escaping (Handles) -> Void) {
        let shouldEnqueue = lock.withLock { () -> Bool in
            guard !pendingAsyncRequest else { return false }
            pendingAsyncRequest = true
            return true
        }
        guard shouldEnqueue else { return }
        queue.async { [weak self] in
            self?.lock.withLock { self?.pendingAsyncRequest = false }
            try? self?.rebuildOnQueue(build: build, teardown: teardown)
        }
    }

    /// Tears down whatever is currently installed, builds a fresh value,
    /// and installs it — unless this coordinator was stopped while
    /// building, in which case the fresh value is torn down instead of
    /// resurrecting a source told to stop. Must run on `queue`, which both
    /// `runSync` and `runAsync` guarantee, so this body never overlaps
    /// itself: the invariant that keeps two builds' handles from ever
    /// being installed at once.
    private func rebuildOnQueue(build: () throws -> Handles, teardown: (Handles) -> Void) throws {
        let (previous, alreadyStopped) = lock.withLock { () -> (Handles?, Bool) in
            let value = current
            current = nil
            return (value, isStopped)
        }
        guard !alreadyStopped else { return }
        if let previous {
            teardown(previous)
        }
        let next = try build()
        let stoppedWhileBuilding = lock.withLock { () -> Bool in
            guard !isStopped else { return true }
            current = next
            return false
        }
        if stoppedWhileBuilding {
            teardown(next)
        }
    }
}
