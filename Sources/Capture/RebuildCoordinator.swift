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
    /// tears its freshly built result back down instead of installing it
    /// — this method alone does not wait for that to happen, so its `nil`
    /// return can't tell "nothing was installed" apart from "a rebuild is
    /// still mid-build and will discard its own result." Callers that
    /// need to know nothing is left running afterward use
    /// `markStoppedAndDrainInFlight()` instead.
    func markStopped() -> Handles? {
        lock.withLock {
            let value = current
            current = nil
            isStopped = true
            return value
        }
    }

    /// `markStopped()`, then blocks the caller until any pass currently
    /// running on `queue` (or still only enqueued, not yet started) has
    /// fully finished — including a build that was still in flight when
    /// this was called discarding its own result once it notices
    /// `isStopped`. Lets a caller like `ProcessTapSource.stop()` return
    /// only once nothing is left building or installed anywhere.
    func markStoppedAndDrainInFlight() -> Handles? {
        let handles = markStopped()
        queue.sync {}
        return handles
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
    /// `onFailure`, when given, is called with whatever `build`/`teardown`
    /// threw — the caller's one chance to observe a failed rebuild that
    /// this method's own `async` shape would otherwise let vanish
    /// silently.
    func runAsync(build: @escaping () throws -> Handles, teardown: @escaping (Handles) -> Void, onFailure: (@Sendable (Error) -> Void)? = nil) {
        let shouldEnqueue = lock.withLock { () -> Bool in
            guard !pendingAsyncRequest else { return false }
            pendingAsyncRequest = true
            return true
        }
        guard shouldEnqueue else { return }
        queue.async { [weak self] in
            self?.lock.withLock { self?.pendingAsyncRequest = false }
            do {
                try self?.rebuildOnQueue(build: build, teardown: teardown)
            } catch {
                onFailure?(error)
            }
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
