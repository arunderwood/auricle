import Core
import Foundation
import State

/// Periodic-poll scaffold for FR46's retention grace timer: on each tick,
/// fetches every `retention_timers` row that is `status = 'pending'` and
/// `fires_at <= now`, and invokes the injected `handler` once per row. This
/// story ships the polling mechanism only — the handler that actually
/// deletes cached audio is Epic 8's; here it's whatever the caller (in
/// production, eventually; a spy, in tests) supplies.
public actor RetentionScheduler {
    public typealias Handler = @Sendable (RetentionTimer) async -> Void

    private let stateStore: StateStore
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let handler: Handler
    private let log = Log(category: "orchestrator")

    public init(
        stateStore: StateStore,
        interval: TimeInterval = 10,
        now: @escaping @Sendable () -> Date = { Date() },
        handler: @escaping Handler,
    ) {
        self.stateStore = stateStore
        self.interval = interval
        self.now = now
        self.handler = handler
    }

    /// One polling pass, directly callable for deterministic tests: fetches
    /// the due rows and runs `handler` over each, returning what it acted
    /// on. A row that is not yet due, or not `pending`, is left untouched —
    /// `StateStore.fetchDueRetentionTimers` already excludes it.
    @discardableResult
    public func pollOnce() async throws -> [RetentionTimer] {
        let due = try await stateStore.fetchDueRetentionTimers(asOf: ISO8601UTC.string(from: now()))
        for timer in due {
            await handler(timer)
        }
        return due
    }

    /// Runs `pollOnce` on `interval` until the task is cancelled. Cancelling
    /// mid-sleep stops the loop before its next poll rather than after —
    /// `Task.sleep` throws `CancellationError` on cancellation, which this
    /// propagates instead of swallowing. A `pollOnce` failure, by contrast,
    /// is logged and swallowed: one transient error (a busy database, say)
    /// shouldn't permanently stop a periodic loop that has no supervisor to
    /// restart it.
    public func run() async throws {
        while !Task.isCancelled {
            do {
                try await pollOnce()
            } catch {
                log.warn("retention scheduler poll failed; will retry next tick", [
                    "error": .publicSafe(String(describing: error)),
                ])
            }
            try await Task.sleep(for: .seconds(interval))
        }
    }
}
