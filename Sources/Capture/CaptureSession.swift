import AVFoundation
import Core
import CoreAudio
import Foundation
import Permissions

/// Whether the microphone ended up in the mix. `false` only when
/// `PermissionChecker.check(.microphone)` reports `.denied` at `start()` —
/// every other status (`.granted`, `.notDetermined`, `.unknown`) still
/// tries the mic, since a missing or undetermined answer is not the same
/// as a denial (AC's mic-denied scenario is specifically about `.denied`).
public struct CaptureSessionStartResult: Sendable, Equatable {
    public let micIncluded: Bool

    public init(micIncluded: Bool) {
        self.micIncluded = micIncluded
    }
}

/// The subset of `WAVWriter`'s API `CaptureSession`'s consumer task drives
/// — a seam so a test can inject a deliberately slow writer to prove the
/// real-time callback thread never blocks on it (NFR-P13), without
/// touching `WAVWriter` itself. Not `Sendable`: `WAVWriter` isn't, and
/// retroactively declaring it so from this file isn't possible — safe
/// regardless, since `CaptureSession` (itself `@unchecked Sendable`) only
/// ever touches a `CaptureAudioWriting` from its one consumer task while
/// running, and from `stop()` only after that task has fully exited.
public protocol CaptureAudioWriting {
    func write(_ samples: Data) throws
    func finalize() throws
}

extension WAVWriter: CaptureAudioWriting {}

/// Wires the microphone (`AVAudioEngine`) and system audio
/// (`SystemAudioSource`) through `AudioMixer` into `WAVWriter` — Decision
/// 1.4's capture format, mono 16 kHz PCM16. One instance captures one
/// meeting once: `start()` past the first call throws rather than
/// silently reusing engine/tap state that a prior `stop()` already tore
/// down.
///
/// Real-time safety (NFR-P13): the mic tap's callback and
/// `SystemAudioSource`'s IOProc callback only ever copy raw samples into a
/// preallocated ring buffer (`micRing`, and the source's own internal
/// ring) and return — no locks beyond the ring's own bounded one, no
/// allocation, no I/O, no logging. All resampling, mixing, the watchdog,
/// stream alignment and `WAVWriter.write(_:)` happen in `runConsumerLoop()`,
/// a background `Task` `start()` launches and `stop()` awaits the exit of
/// before touching `mixer`/`writer` itself. That sequencing is what makes
/// `mixer`/`writer` single-writer by construction: only ever the consumer
/// task while it runs, and only ever `stop()` after it has fully finished
/// — the concurrency contract `WAVWriter`'s own deferred-work entry asked
/// this story to settle (see the spec's Design Notes).
///
/// `@unchecked Sendable`: every mutable field is touched only while `lock`
/// is held.
public final class CaptureSession: @unchecked Sendable {
    static let log = Log(category: "capture-session")
    static let consumerPollInterval: Duration = .milliseconds(20)
    private static let micRingSlotCount = 64
    private static let micRingSlotCapacityFrames = 8192
    private static let micRingMaxChannels = 2
    static let effectiveRateCheckWindowSeconds: Double = 1
    static let effectiveRateToleranceFraction = 0.05
    static let maxHeldAlignmentChunks = 200
    /// Caps how much leading silence stream alignment will ever prime one
    /// side with — 30 seconds of 16kHz frames. A legitimate startup offset
    /// between the mic and system clocks is a fraction of a second; this
    /// bound exists only to turn a corrupt host-time delta (e.g. an
    /// uptime-scale value slipping past the `> 0` validity checks
    /// upstream) into a large-but-bounded allocation instead of one sized
    /// by days of system uptime.
    static let maxLeadInFrames = AudioImporter.sampleRate * 30

    enum Phase: Equatable {
        case idle
        /// Reserved atomically by `start()` before any async work begins,
        /// so two concurrent `start()` calls can't both pass the `.idle`
        /// guard and both stand up a tap/engine/writer.
        case starting
        case running
        /// Reserved atomically by `stop()` before releasing the lock for
        /// teardown, so two concurrent `stop()` calls can't both observe
        /// `.running` and both run the full teardown/flush/finalize path.
        case stopping
        case stopped(path: String)
        /// A terminal state for a `start()`/`stop()` that threw partway
        /// through — a retried `stop()` re-throws this instead of redoing
        /// `systemAudioSource.stop()`/`stopMicInput()`/`finalize()`; a
        /// `start()` that reached this never gets retried, matching this
        /// type's single-use contract.
        case stopFailed(reason: String)
    }

    let meetingID: MeetingID
    private let engine: AVAudioEngine
    let systemAudioSource: SystemAudioSource
    private let permissionChecker: PermissionChecking
    let cacheDirectory: @Sendable (MeetingID) throws -> URL
    /// Test seam: production always calls `AVAudioEngine.start()`, but a
    /// concrete `AVAudioEngine` can't otherwise be made to fail
    /// deterministically without real audio hardware.
    private let startEngine: @Sendable (AVAudioEngine) throws -> Void
    /// Test seam: overrides the real `WAVWriter` construction, e.g. with a
    /// deliberately slow writer to prove the producer side never blocks on
    /// it.
    private let makeWriter: (@Sendable (MeetingID) throws -> CaptureAudioWriting)?
    let noCallbackThreshold: TimeInterval

    let micRing = AudioRingBuffer(slotCount: micRingSlotCount, slotCapacityFrames: micRingSlotCapacityFrames, maxChannels: micRingMaxChannels)

    let lock = NSLock()
    var phase: Phase = .idle
    var mixer: AudioMixer?
    var writer: CaptureAudioWriting?
    var micIncluded = false
    private var consumerTask: Task<Void, Never>?
    var watchdog = SystemAudioWatchdog()
    /// The first error `WAVWriter.write(_:)` raised, if any — a disk-full
    /// or similar write failure that `drainOnce` catches rather than lets
    /// `try?` swallow, so it's visible in `watchdogStats` instead of
    /// silently losing audio. `stop()` still returns the capture's path
    /// normally on a write error rather than failing the whole capture
    /// over it — system audio loss already degrades to mic-only rather
    /// than failing, and a partially-written recording is worth more to
    /// the caller than none.
    var firstWriteError: CaptureError?

    public init(
        meetingID: MeetingID,
        engine: AVAudioEngine = AVAudioEngine(),
        systemAudioSource: SystemAudioSource = ProcessTapSource(),
        permissionChecker: PermissionChecking = PermissionChecker(),
        cacheDirectory: @escaping @Sendable (MeetingID) throws -> URL = { try CacheArtifactWriter.cacheDirectory(for: $0) },
        startEngine: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        makeWriter: (@Sendable (MeetingID) throws -> CaptureAudioWriting)? = nil,
        // Matches `SystemAudioWatchdog.noCallbackRebuildThreshold`, which
        // is `internal` (a `public` default argument can only reference
        // `public` symbols) — tests override this to a much shorter
        // interval instead of waiting out the real threshold.
        noCallbackThreshold: TimeInterval = 5,
    ) {
        self.meetingID = meetingID
        self.engine = engine
        self.systemAudioSource = systemAudioSource
        self.permissionChecker = permissionChecker
        self.cacheDirectory = cacheDirectory
        self.startEngine = startEngine
        self.makeWriter = makeWriter
        self.noCallbackThreshold = noCallbackThreshold
    }

    /// A snapshot of the system-audio watchdog's counters, for Story 5.4's
    /// capture metadata to read once it exists.
    public var watchdogStats: CaptureWatchdogStats {
        let systemRingStats = systemAudioSource.ringLossStats
        let micRingStats = micRing.snapshotDropStats()
        lock.lock()
        defer { lock.unlock() }
        return CaptureWatchdogStats(
            exactZeroSeconds: watchdog.exactZeroSeconds,
            rebuildCount: watchdog.rebuildCount,
            rateCorrectionCount: watchdog.rateCorrectionCount,
            systemRingDroppedChunkCount: systemRingStats.droppedChunkCount,
            systemRingTruncatedChunkCount: systemRingStats.truncatedChunkCount,
            micRingDroppedChunkCount: micRingStats.droppedChunkCount,
            micRingTruncatedChunkCount: micRingStats.truncatedChunkCount,
            firstWriteErrorDescription: firstWriteError.map { String(describing: $0) },
        )
    }

    /// Starts system audio unconditionally and the microphone unless
    /// `PermissionChecker.check(.microphone)` reports `.denied`. Builds
    /// `WAVWriter` before starting either source: a buffer has nowhere to
    /// go if it arrives before the writer exists, so building the writer
    /// first is what keeps every buffer from every capture writable from
    /// the moment either source can produce one.
    public func start() async throws -> CaptureSessionStartResult {
        try lock.withLock {
            guard phase == .idle else {
                throw CaptureError.streamInterrupted(reason: "CaptureSession is single-use; start() was already called")
            }
            phase = .starting
        }

        let micStatus = await permissionChecker.check(.microphone)
        let includeMic = micStatus != .denied
        let mixer = AudioMixer()

        let writer: CaptureAudioWriting
        do {
            writer = if let makeWriter {
                try makeWriter(meetingID)
            } else {
                try WAVWriter(meetingID: meetingID, cacheDirectory: cacheDirectory)
            }
        } catch {
            lock.withLock { phase = .stopFailed(reason: String(describing: error)) }
            throw error
        }

        do {
            try systemAudioSource.start()
        } catch {
            lock.withLock { phase = .stopFailed(reason: String(describing: error)) }
            throw error
        }

        if includeMic {
            do {
                try startMicInput()
            } catch {
                systemAudioSource.stop()
                lock.withLock { phase = .stopFailed(reason: String(describing: error)) }
                throw error
            }
        }

        lock.withLock {
            self.mixer = mixer
            self.writer = writer
            micIncluded = includeMic
            phase = .running
        }

        consumerTask = Task { [weak self] in
            await self?.runConsumerLoop()
        }

        return CaptureSessionStartResult(micIncluded: includeMic)
    }

    /// Flushes both sources and finalizes `audio.wav`, returning its path.
    /// Idempotent per NFR-R5: a second call, or a call before `start()`,
    /// never touches an already-torn-down engine/tap twice. `phase`
    /// always lands on a terminal state before this returns or throws —
    /// including on a mid-teardown failure — so a retried `stop()` never
    /// repeats teardown.
    private enum StopDecision {
        case invalidBeforeRunning
        case alreadyStopping
        case alreadyStopped(URL)
        case alreadyFailed(reason: String)
        case proceed(includeMic: Bool, task: Task<Void, Never>?)
    }

    /// Atomically reserves `.stopping` when `phase == .running`, or reports
    /// what the caller should do instead — the one moment `phase` is read
    /// and (on the running path) written under `lock`.
    private func resolveStopDecision() -> StopDecision {
        lock.withLock {
            switch phase {
            case .idle, .starting:
                return .invalidBeforeRunning
            case .stopping:
                return .alreadyStopping
            case let .stopped(path):
                return .alreadyStopped(URL(fileURLWithPath: path))
            case let .stopFailed(reason):
                return .alreadyFailed(reason: reason)
            case .running:
                phase = .stopping
                return .proceed(includeMic: micIncluded, task: consumerTask)
            }
        }
    }

    @discardableResult
    public func stop() async throws -> URL {
        let includeMic: Bool
        let task: Task<Void, Never>?
        switch resolveStopDecision() {
        case .invalidBeforeRunning:
            throw CaptureError.streamInterrupted(reason: "CaptureSession.stop() called before start() completed")
        case .alreadyStopping:
            throw CaptureError.streamInterrupted(reason: "CaptureSession.stop() is already in progress")
        case let .alreadyStopped(url):
            return url
        case let .alreadyFailed(reason):
            throw CaptureError.streamInterrupted(reason: reason)
        case let .proceed(proceedIncludeMic, proceedTask):
            includeMic = proceedIncludeMic
            task = proceedTask
        }

        // Stopping both sources first guarantees no further chunks are
        // ever published; awaiting the consumer task's exit next
        // guarantees it has finished whatever it was already doing with
        // `mixer`/`writer` — including a final drain of anything queued
        // right before this point — before `finalizeCapture()` touches
        // either itself. This ordering is required because a write to an
        // already-`finalize()`d `FileHandle` raises an uncatchable
        // exception, not a catchable Swift error, so the two must never
        // be able to overlap.
        systemAudioSource.stop()
        if includeMic {
            stopMicInput()
        }
        task?.cancel()
        await task?.value

        return try finalizeCapture()
    }

    /// Flushes whatever's left in `mixer`, finalizes `writer`, and lands
    /// `phase` on a terminal state either way. Called only after `stop()`
    /// has confirmed the consumer task has fully exited.
    private func finalizeCapture() throws -> URL {
        let mixer = lock.withLock { self.mixer }
        let writer = lock.withLock { self.writer }
        do {
            if let mixer, let writer {
                let remaining = mixer.peekFlush()
                if !remaining.isEmpty {
                    try writer.write(remaining)
                    mixer.discardFlushed()
                }
            }
            try writer?.finalize()

            let url = try cacheDirectory(meetingID).appendingPathComponent(AudioImporter.audioFileName)
            lock.withLock { phase = .stopped(path: url.path) }
            return url
        } catch {
            let reason = String(describing: error)
            lock.withLock { phase = .stopFailed(reason: reason) }
            throw error
        }
    }

    // MARK: - Microphone

    private func startMicInput() throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
            self?.publishMicBuffer(buffer, time: time)
        }
        do {
            try startEngine(engine)
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.streamInterrupted(reason: "microphone engine failed to start: \(error.localizedDescription)")
        }
    }

    private func stopMicInput() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Producer-side (the mic-tap real-time callback): copies raw samples
    /// into `micRing` and returns — no locks beyond the ring's own bounded
    /// one, no allocation, no I/O, no logging (NFR-P13). All resampling,
    /// mixing and writing happens in `runConsumerLoop()`, off this thread.
    /// A buffer with no valid host time is dropped rather than published
    /// with a placeholder: `resolveAlignmentIfPossible` compares host
    /// times across the mic and system streams, and a placeholder would
    /// read as a real, comparable timestamp instead of the "unknown" it
    /// actually is.
    private func publishMicBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channelData = buffer.floatChannelData, time.isHostTimeValid else { return }
        micRing.publish(
            channelData: channelData,
            channelCount: Int(buffer.format.channelCount),
            frameCount: Int(buffer.frameLength),
            sampleRate: buffer.format.sampleRate,
            hostTime: time.hostTime,
            sampleTime: time.isSampleTimeValid ? Double(time.sampleTime) : 0,
        )
    }
}
