import Core
import Foundation
import Notifications
import State
import Telemetry

/// What `CaptureStage.start` hands back: the new meeting, and whether the
/// microphone made it into the mix.
public struct CaptureStartResult: Sendable, Equatable {
    public let meetingID: MeetingID
    public let micIncluded: Bool

    public init(meetingID: MeetingID, micIncluded: Bool) {
        self.meetingID = meetingID
        self.micIncluded = micIncluded
    }
}

/// Where launch recovery left one orphaned `recording` row.
public struct CaptureRecoveryOutcome: Sendable, Equatable {
    public let meetingID: MeetingID
    public let state: PipelineState

    public init(meetingID: MeetingID, state: PipelineState) {
        self.meetingID = meetingID
        self.state = state
    }
}

/// Raised by `CaptureStage.stop` for a row whose `state` this build does not
/// recognize.
public enum CaptureStageError: Error, Sendable, Equatable {
    case unrecognizedState(meetingID: MeetingID, state: String)
    /// `start` was called while `meetingID` is still being captured.
    case captureAlreadyLive(meetingID: MeetingID)
}

/// The capture stage: owns a meeting from the moment recording starts until
/// it is `captured` or `capture_failed`.
///
/// Capture does not go through `StageRunner.run`, which runs one closure over
/// a row that already exists. Here the row is created at start, and start and
/// stop are separate user actions that can be hours apart. The stage writes
/// the same two transactions directly: `StateStore.beginCapture` (the row in
/// `recording` plus the `started` event) and `StateStore.finishCapture` (end
/// time, duration and state plus the `completed` or `failed` event, guarded on
/// the row still being `recording`), both through `StageEventLogger`.
///
/// No permission blocks a start: a denied microphone records system audio
/// alone. Every `start` creates a row, and any failure after that moves it to
/// `capture_failed` with an `error_class`: `start_failed`, `interrupted`,
/// `permission_revoked_midstream` or `transient_stream_errors`.
///
/// A row left `recording` by a crash has no live session. Launch recovery
/// repairs its WAV header and moves it to `captured` when audio made it to
/// disk, and to `capture_failed` (`interrupted`) when none did.
///
/// Only a capture that `stop()` landed in `captured` is handed to the
/// pipeline, through `onCaptured`. A meeting launch recovery relabels
/// `recovered_after_interruption` waits for the user, and so does a stopped
/// capture whose `captured` write failed, since recovery relabels that one
/// too: its audio ended where the interruption ended it, and the user
/// decides whether it is worth processing.
///
/// `endedCaptures` yields a meeting's id each time it stops being live, by
/// whatever path: a stop, a fault that failed it, or a start that failed.
public actor CaptureStage {
    public typealias SessionFactory = @Sendable (MeetingID) -> any CaptureRecording

    enum ErrorClass {
        static let startFailed = "start_failed"
        static let interrupted = "interrupted"
        static let permissionRevokedMidstream = "permission_revoked_midstream"
        static let transientStreamErrors = "transient_stream_errors"
        static let allSourcesLost = "all_sources_lost"
    }

    /// `previous_error_class` on a `retried` event: an inline restart follows
    /// a stream interruption; a backoff attempt follows the loss of system
    /// audio.
    enum RetryCause {
        static let streamInterrupted = "stream_interrupted"
        static let systemAudioLost = "system_audio_lost"
    }

    /// The wait before each backoff attempt to bring lost system audio back:
    /// 5 s, 15 s, 30 s, then every 60 s. `attempt` counts from 0.
    public static func defaultSystemAudioRetryDelay(attempt: Int) -> Duration {
        switch attempt {
        case 0: .seconds(5)
        case 1: .seconds(15)
        case 2: .seconds(30)
        default: .seconds(60)
        }
    }

    static let recoveredReason = "recovered_after_interruption"

    enum Phase {
        /// `session.start()` has not returned. A stop that arrives now is
        /// held until it does.
        case starting(stopRequested: Bool)
        case running
        /// A stop or a fault is tearing the capture down; anything else that
        /// arrives for it is ignored.
        case finishing
    }

    /// When system audio was lost and restored, for the capture's metadata.
    struct SystemAudioLoss {
        var lostAt: Date?
        var restoredAt: Date?
        var count = 0
    }

    struct LiveCapture {
        let session: any CaptureRecording
        let startedAt: Date
        var phase: Phase
        var micIncluded = false
        /// One cap per input: a flapping system tap must not use up the
        /// microphone's allowance, or the reverse.
        var micPolicy = TransientRestartPolicy()
        var systemPolicy = TransientRestartPolicy()
        /// True while system audio is lost and the capture is microphone-only.
        var systemAudioLost = false
        var systemAudioLoss = SystemAudioLoss()
        var systemAudioRetries: Task<Void, Never>?
    }

    static let log = Log(category: "capture-stage")
    static let wavHeaderBytes: UInt64 = 44

    let stateStore: StateStore
    let stageEventLogger: StageEventLogger
    private let notifier: any Notifier
    private let makeSession: SessionFactory
    let cacheDirectory: @Sendable (MeetingID) throws -> URL
    let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    private let onCaptured: @Sendable (MeetingID) async -> Void
    let systemAudioRetryDelay: @Sendable (Int) -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    var live: [MeetingID: LiveCapture] = [:]

    /// Single consumer: an `AsyncStream` delivers each element to one
    /// iterator. Buffers only the newest few, because a Release build has no
    /// consumer and a capture's end is only news while it is recent.
    public nonisolated let endedCaptures: AsyncStream<MeetingID>
    private let endedContinuation: AsyncStream<MeetingID>.Continuation

    /// `makeSession` defaults to a `LiveCaptureSession` writing under
    /// `cacheDirectory`, so the path stored in `audio_cache_path` is the path
    /// the session writes. `timeZone` is read at each start, so a Mac that
    /// travels records each meeting in the zone it was in. `onCaptured` runs
    /// in its own task after a stop lands `captured`; a failed or recovered
    /// capture never reaches it. `systemAudioRetryDelay` and `sleep` pace the
    /// backoff that tries to bring lost system audio back; tests replace both
    /// so they never wait in real time.
    public init(
        stateStore: StateStore,
        stageEventLogger: StageEventLogger,
        notifier: any Notifier,
        makeSession: SessionFactory? = nil,
        cacheDirectory: @escaping @Sendable (MeetingID) throws -> URL = { try CacheArtifactWriter.cacheDirectory(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        onCaptured: @escaping @Sendable (MeetingID) async -> Void = { _ in },
        systemAudioRetryDelay: @escaping @Sendable (Int) -> Duration = CaptureStage.defaultSystemAudioRetryDelay(attempt:),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ) {
        self.stateStore = stateStore
        self.stageEventLogger = stageEventLogger
        self.notifier = notifier
        self.makeSession = makeSession ?? { LiveCaptureSession(meetingID: $0, cacheDirectory: cacheDirectory) }
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.timeZone = timeZone
        self.onCaptured = onCaptured
        self.systemAudioRetryDelay = systemAudioRetryDelay
        self.sleep = sleep
        (endedCaptures, endedContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// The one way a meeting leaves `live`, so `endedCaptures` hears of
    /// every exit.
    func endLive(_ meetingID: MeetingID) {
        guard live.removeValue(forKey: meetingID) != nil else { return }
        endedContinuation.yield(meetingID)
    }

    // MARK: - Start

    /// Writes the `recording` row and its `started` event, then starts the
    /// session. A session that fails to start moves the row to
    /// `capture_failed` (`start_failed`) and its error is rethrown.
    public func start(meetingID: MeetingID = .generate()) async throws -> CaptureStartResult {
        // One meeting at a time: a second capture would either collide with
        // this one's row or leave it recording with nothing tracking it.
        if let liveID = live.keys.first {
            throw CaptureStageError.captureAlreadyLive(meetingID: liveID)
        }
        let startedAt = now()
        let stamp = ISO8601UTC.string(from: startedAt)
        let audioPath = try? cacheDirectory(meetingID).appendingPathComponent(AudioImporter.audioFileName).path

        // Registered before the row is written, so a launch recovery that
        // reads the new `recording` row always finds it live.
        let session = makeSession(meetingID)
        live[meetingID] = LiveCapture(session: session, startedAt: startedAt, phase: .starting(stopRequested: false))
        do {
            try await stageEventLogger.recordCaptureStarted(
                meeting: recordingRow(meetingID, stamp: stamp, audioPath: audioPath),
                occurredAt: stamp,
            )
        } catch {
            endLive(meetingID)
            throw error
        }

        let result: CaptureSessionStartResult
        do {
            result = try await session.start()
        } catch {
            live[meetingID]?.phase = .finishing
            // The session is single-use and may hold a half-built writer or
            // tap; stopping it releases whatever it got to.
            _ = try? await session.stop()
            await finishFailed(meetingID, startedAt: startedAt, errorClass: ErrorClass.startFailed, error: error)
            endLive(meetingID)
            throw error
        }

        let stopRequested = if case .starting(stopRequested: true) = live[meetingID]?.phase {
            true
        } else {
            false
        }
        live[meetingID]?.phase = .running
        live[meetingID]?.micIncluded = result.micIncluded
        watchFaults(of: session, for: meetingID)
        Self.log.info("capture started", [
            "meeting_id": .publicSafe(meetingID.rawValue),
            "mic_included": .publicSafe(result.micIncluded),
        ])

        if stopRequested {
            await runDeferredStop(meetingID)
        }
        return CaptureStartResult(meetingID: meetingID, micIncluded: result.micIncluded)
    }

    /// Not cancelled by stop or fail: a fault handler runs on this task, and
    /// cancelling it would cancel the handler's own database writes. The loop
    /// ends when the session finishes `faults` as it stops.
    private func watchFaults(of session: any CaptureRecording, for meetingID: MeetingID) {
        Task { [weak self] in
            for await fault in session.faults {
                await self?.handle(fault, for: meetingID)
            }
        }
    }

    /// The session did start, so a deferred stop that fails does not fail
    /// `start`: the stop's own outcome is already on the row.
    private func runDeferredStop(_ meetingID: MeetingID) async {
        do {
            _ = try await stop(meetingID: meetingID)
        } catch {
            Self.log.warn("a stop requested during start failed", [
                "meeting_id": .publicSafe(meetingID.rawValue),
                "reason": .sensitive(String(describing: error)),
            ])
        }
    }

    // MARK: - Stop

    /// Stops a live capture and moves it to `captured`, or to
    /// `capture_failed` (`interrupted`) when the session cannot finalize its
    /// audio. For a meeting with no live capture it writes nothing and returns
    /// the row's state, so a second stop is harmless. A stop that arrives
    /// while the session is still starting is carried out once it has
    /// started, and this call returns `recording`.
    public func stop(meetingID: MeetingID) async throws -> PipelineState {
        guard let capture = live[meetingID] else {
            return try await storedState(of: meetingID)
        }
        switch capture.phase {
        case .starting:
            live[meetingID]?.phase = .starting(stopRequested: true)
            return .recording
        case .finishing:
            return try await storedState(of: meetingID)
        case .running:
            break
        }

        live[meetingID]?.phase = .finishing
        live[meetingID]?.systemAudioRetries?.cancel()
        let loss = live[meetingID]?.systemAudioLoss ?? SystemAudioLoss()
        let audioURL: URL
        do {
            audioURL = try await capture.session.stop()
        } catch {
            repairAudioAfterFailedFinalize(meetingID)
            await finishFailed(
                meetingID,
                startedAt: capture.startedAt,
                errorClass: ErrorClass.interrupted,
                loss: loss,
                stats: capture.session.watchdogStats,
                error: error,
            )
            endLive(meetingID)
            return .captureFailed
        }

        // Read after `stop()`: its final drain can still add to the counters.
        let stats = capture.session.watchdogStats
        let endedAt = now()
        let meta = Self.withLoss(loss, Self.withStats(stats, CaptureMeta(micIncluded: capture.micIncluded)))
        defer { endLive(meetingID) }
        try await stageEventLogger.recordCaptureFinished(
            meetingID: meetingID,
            kind: .completed,
            targetState: .captured,
            occurredAt: ISO8601UTC.string(from: endedAt),
            endedAt: ISO8601UTC.string(from: endedAt),
            durationSeconds: Self.audioDurationSeconds(at: audioURL) ?? Self.wholeSeconds(from: capture.startedAt, to: endedAt),
            durationMS: Self.milliseconds(from: capture.startedAt, to: endedAt),
            metadataJSON: Self.encode(meta),
        )
        Self.log.info("capture stopped", ["meeting_id": .publicSafe(meetingID.rawValue)])

        let onCaptured = onCaptured
        Task { await onCaptured(meetingID) }
        return .captured
    }

    private func recordingRow(_ meetingID: MeetingID, stamp: String, audioPath: String?) -> Meeting {
        Meeting(
            id: meetingID.rawValue,
            state: PipelineState.recording.rawValue,
            createdAt: stamp,
            updatedAt: stamp,
            captureStartedAt: stamp,
            audioCachePath: audioPath,
            captureTimeZone: timeZone().identifier,
        )
    }
}

/// Fault handling: inline restarts, and failing a capture that cannot go on.
extension CaptureStage {
    // MARK: - Faults

    private func handle(_ fault: CaptureStreamFault, for meetingID: MeetingID) async {
        guard let capture = live[meetingID], case .running = capture.phase else { return }
        switch fault {
        case let .permissionRevoked(source):
            await fail(meetingID, errorClass: ErrorClass.permissionRevokedMidstream, source: source, error: CaptureError.permissionRevokedMidstream)
            await notifier.fireCaptureFailed(meetingID: meetingID, reason: .permissionRevokedMidstream)
        case let .transient(.systemAudio, reason):
            // While lost, the backoff owns system audio; the session's own
            // watchdog rebuilds keep failing and reporting, and are ignored.
            guard !capture.systemAudioLost else { return }
            guard live[meetingID]?.systemPolicy.record(at: now()) == .restart else {
                await loseSystemAudio(meetingID, reason: reason)
                return
            }
            let attempt = live[meetingID]?.systemPolicy.faultsInWindow ?? 0
            await restart(.systemAudio, of: meetingID, after: reason, attempt: attempt, session: capture.session)
        case let .transient(.microphone, reason):
            guard live[meetingID]?.micPolicy.record(at: now()) == .restart else {
                await fail(
                    meetingID,
                    errorClass: capture.systemAudioLost ? ErrorClass.allSourcesLost : ErrorClass.transientStreamErrors,
                    source: .microphone,
                    error: CaptureError.streamInterrupted(reason: reason),
                )
                return
            }
            let attempt = live[meetingID]?.micPolicy.faultsInWindow ?? 0
            await restart(.microphone, of: meetingID, after: reason, attempt: attempt, session: capture.session)
        }
    }

    /// One `retried` event per inline restart, numbered by the source's faults
    /// in the current window. A restart that throws is handled as the next
    /// fault, so a source that keeps failing reaches the cap.
    private func restart(
        _ source: CaptureSource,
        of meetingID: MeetingID,
        after reason: String,
        attempt: Int,
        session: any CaptureRecording,
    ) async {
        await recordRetry(
            CaptureMeta(source: source.rawValue, attemptNumber: attempt, previousErrorClass: RetryCause.streamInterrupted, backoffMS: 0),
            for: meetingID,
            reason: reason,
        )

        // Both awaits here let a stop or a fail run in between; a capture
        // that has left `.running` is not restarted, and a restart error
        // arriving after it left is not a fault of a live capture.
        guard case .running = live[meetingID]?.phase else { return }
        do {
            try await session.restart(source)
        } catch {
            guard case .running = live[meetingID]?.phase else { return }
            if case CaptureError.permissionRevokedMidstream = error {
                await handle(.permissionRevoked(source), for: meetingID)
            } else {
                await handle(.transient(source, reason: String(describing: error)), for: meetingID)
            }
        }
    }

    /// Stops the session, which finalizes the partial WAV so the audio
    /// already captured survives, then fails the row.
    func fail(_ meetingID: MeetingID, errorClass: String, source: CaptureSource, error: Error) async {
        guard let capture = live[meetingID] else { return }
        live[meetingID]?.phase = .finishing
        capture.systemAudioRetries?.cancel()
        do {
            _ = try await capture.session.stop()
        } catch {
            Self.log.warn("the failed capture's audio could not be finalized", [
                "meeting_id": .publicSafe(meetingID.rawValue),
                "reason": .sensitive(String(describing: error)),
            ])
            repairAudioAfterFailedFinalize(meetingID)
        }
        await finishFailed(
            meetingID,
            startedAt: capture.startedAt,
            errorClass: errorClass,
            source: source,
            loss: capture.systemAudioLoss,
            stats: capture.session.watchdogStats,
            error: error,
        )
        endLive(meetingID)
    }
}

/// The row writes every path shares, and the helpers they use.
extension CaptureStage {
    // MARK: - Writes

    /// Moves the row to `capture_failed`. A write that cannot land is logged,
    /// not thrown: the caller is already reporting a failure of its own, and
    /// a row left `recording` is settled by the next launch's recovery.
    private func finishFailed(
        _ meetingID: MeetingID,
        startedAt: Date,
        errorClass: String,
        source: CaptureSource? = nil,
        loss: SystemAudioLoss = SystemAudioLoss(),
        stats: CaptureWatchdogStats? = nil,
        error: Error,
    ) async {
        var meta = CaptureMeta(errorClass: errorClass, source: source?.rawValue)
        if let stats {
            meta = Self.withStats(stats, meta)
        }
        let endedAt = now()
        do {
            try await stageEventLogger.recordCaptureFinished(
                meetingID: meetingID,
                kind: .failed,
                targetState: .captureFailed,
                occurredAt: ISO8601UTC.string(from: endedAt),
                endedAt: ISO8601UTC.string(from: endedAt),
                durationSeconds: Self.wholeSeconds(from: startedAt, to: endedAt),
                durationMS: Self.milliseconds(from: startedAt, to: endedAt),
                errorMessage: String(describing: error),
                metadataJSON: Self.encode(Self.withLoss(loss, meta)),
            )
        } catch {
            Self.log.error("could not record a failed capture", [
                "meeting_id": .publicSafe(meetingID.rawValue),
                "reason": .sensitive(String(describing: error)),
            ])
        }
        Self.log.warn("capture failed", [
            "meeting_id": .publicSafe(meetingID.rawValue),
            "error_class": .publicSafe(errorClass),
        ])
    }

    private func storedState(of meetingID: MeetingID) async throws -> PipelineState {
        guard let meeting = try await stateStore.fetchMeeting(id: meetingID.rawValue) else {
            throw StateStoreError.meetingNotFound(id: meetingID.rawValue)
        }
        guard let state = PipelineState(rawValue: meeting.state) else {
            throw CaptureStageError.unrecognizedState(meetingID: meetingID, state: meeting.state)
        }
        return state
    }

    // MARK: - Helpers

    /// `meta` with the session's watchdog counters and its first write
    /// error. `write_error` stays absent when every write succeeded.
    private static func withStats(_ stats: CaptureWatchdogStats, _ meta: CaptureMeta) -> CaptureMeta {
        var meta = meta
        meta.exactZeroSeconds = stats.exactZeroSeconds
        meta.tapRebuilds = stats.rebuildCount
        meta.systemRingDroppedChunks = stats.systemRingDroppedChunkCount
        meta.systemRingTruncatedChunks = stats.systemRingTruncatedChunkCount
        meta.micRingDroppedChunks = stats.micRingDroppedChunkCount
        meta.micRingTruncatedChunks = stats.micRingTruncatedChunkCount
        meta.writeError = stats.firstWriteErrorDescription
        return meta
    }

    /// `meta` with the system-audio loss fields, when there was a loss.
    private static func withLoss(_ loss: SystemAudioLoss, _ meta: CaptureMeta) -> CaptureMeta {
        guard loss.count > 0 else { return meta }
        var meta = meta
        meta.systemAudioLostAt = loss.lostAt.map(ISO8601UTC.string(from:))
        meta.systemAudioRestoredAt = loss.restoredAt.map(ISO8601UTC.string(from:))
        meta.systemAudioLossCount = loss.count
        return meta
    }

    func recordRetry(_ meta: CaptureMeta, for meetingID: MeetingID, reason: String) async {
        do {
            try await stageEventLogger.record(event: StageEventRecord(
                meetingID: meetingID,
                stage: .capture,
                kind: .retried,
                occurredAt: ISO8601UTC.string(from: now()),
                errorMessage: reason,
                metadataJSON: Self.encode(meta),
            ))
        } catch {
            Self.log.warn("could not record a capture retry", [
                "meeting_id": .publicSafe(meetingID.rawValue),
                "reason": .sensitive(String(describing: error)),
            ])
        }
    }

    static func encode(_ meta: CaptureMeta) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(meta)).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// Seconds of audio in a finalized WAV, read from its size.
    private static func audioDurationSeconds(at url: URL) -> Int? {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
            size >= wavHeaderBytes
        else { return nil }
        let seconds = Double(size - wavHeaderBytes) / 2 / Double(AudioImporter.sampleRate)
        return Int(seconds.rounded())
    }

    private static func wholeSeconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start).rounded()))
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
