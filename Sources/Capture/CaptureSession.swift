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
    private static let log = Log(category: "capture-session")
    private static let consumerPollInterval: Duration = .milliseconds(20)
    private static let micRingSlotCount = 64
    private static let micRingSlotCapacityFrames = 8192
    private static let micRingMaxChannels = 2
    private static let effectiveRateCheckWindowSeconds: Double = 1
    private static let effectiveRateToleranceFraction = 0.05
    private static let maxHeldAlignmentChunks = 200

    private enum Phase: Equatable {
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

    private let meetingID: MeetingID
    private let engine: AVAudioEngine
    private let systemAudioSource: SystemAudioSource
    private let permissionChecker: PermissionChecking
    private let cacheDirectory: @Sendable (MeetingID) throws -> URL
    /// Test seam: production always calls `AVAudioEngine.start()`, but a
    /// concrete `AVAudioEngine` can't otherwise be made to fail
    /// deterministically without real audio hardware.
    private let startEngine: @Sendable (AVAudioEngine) throws -> Void
    /// Test seam: overrides the real `WAVWriter` construction, e.g. with a
    /// deliberately slow writer to prove the producer side never blocks on
    /// it.
    private let makeWriter: (@Sendable (MeetingID) throws -> CaptureAudioWriting)?
    private let noCallbackThreshold: TimeInterval

    private let micRing = AudioRingBuffer(slotCount: micRingSlotCount, slotCapacityFrames: micRingSlotCapacityFrames, maxChannels: micRingMaxChannels)

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var mixer: AudioMixer?
    private var writer: CaptureAudioWriting?
    private var micIncluded = false
    private var consumerTask: Task<Void, Never>?
    private var watchdog = SystemAudioWatchdog()

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
        lock.lock()
        defer { lock.unlock() }
        return CaptureWatchdogStats(exactZeroSeconds: watchdog.exactZeroSeconds, rebuildCount: watchdog.rebuildCount)
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
        // either itself. That ordering is the whole fix: a write to an
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
    private func publishMicBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channelData = buffer.floatChannelData else { return }
        micRing.publish(
            channelData: channelData,
            channelCount: Int(buffer.format.channelCount),
            frameCount: Int(buffer.frameLength),
            sampleRate: buffer.format.sampleRate,
            hostTime: time.isHostTimeValid ? time.hostTime : 0,
        )
    }
}

/// The consumer side of `CaptureSession`'s real-time design (see the
/// type's own doc comment): everything here runs on the background `Task`
/// `start()` launches, never on the mic-tap or IOProc callback thread, so
/// it's free to allocate, lock, and do file I/O. A separate `extension`
/// (rather than more of the primary declaration) so the type's real-time
/// contract — what runs where — is visible in the file's own structure,
/// not just its comments.
extension CaptureSession {
    // MARK: - Consumer (off the real-time thread — see the type doc)

    private func runConsumerLoop() async {
        let micIncluded = lock.withLock { self.micIncluded }
        let state = ConsumerAlignmentState(micIncluded: micIncluded)
        var lastSystemActivity = ContinuousClock.now

        while !Task.isCancelled {
            guard let (mixer, writer) = runningComponents() else { break }
            let before = lastSystemActivity
            drainOnce(mixer: mixer, writer: writer, state: state, micIncluded: micIncluded, sawActivity: &lastSystemActivity)
            checkNoCallbackWatchdog(lastSystemActivity: &lastSystemActivity)
            if lastSystemActivity == before {
                try? await Task.sleep(for: Self.consumerPollInterval)
            }
        }

        // A final drain after cancellation, so anything queued right
        // before `stop()` cancelled this task isn't lost before `stop()`'s
        // own flush — `runningComponents()` still returns them during
        // `.stopping`, only becoming nil once `stop()` reaches a terminal
        // phase after this task has already exited.
        if let (mixer, writer) = runningComponents() {
            var unused = lastSystemActivity
            drainOnce(mixer: mixer, writer: writer, state: state, micIncluded: micIncluded, sawActivity: &unused)
        }
    }

    private func drainOnce(mixer: AudioMixer, writer: CaptureAudioWriting, state: ConsumerAlignmentState, micIncluded: Bool, sawActivity: inout ContinuousClock.Instant) {
        systemAudioSource.drain { chunk in
            sawActivity = .now
            self.processSystemChunk(chunk, mixer: mixer, state: state)
        }
        if micIncluded {
            micRing.drainAll { chunk in
                self.processMicChunk(chunk, mixer: mixer, state: state)
            }
        }

        let pcm = mixer.drain()
        if !pcm.isEmpty {
            try? writer.write(pcm)
        }
    }

    private func processSystemChunk(_ chunk: RawAudioChunk, mixer: AudioMixer, state: ConsumerAlignmentState) {
        let isZero = ZeroBufferDetector.isExactZero(chunk.samples)
        let duration = chunk.sampleRate > 0 ? Double(chunk.frameCount) / chunk.sampleRate : 0
        let shouldRebuild = lock.withLock { watchdog.observeBuffer(isExactZero: isZero, duration: duration) }
        if shouldRebuild {
            triggerRebuild(state: state)
        }

        // A stale or wrong declared rate (e.g. AirPods switching to HFP
        // mid-call) would otherwise resample every subsequent buffer at
        // the wrong ratio without ever erroring: once, over the first ~1
        // second of system audio, compare the arrival rate implied by
        // host-time deltas against the tap's declared rate.
        if !state.rateChecked, chunk.sampleRate > 0 {
            if state.rateProbeFirstHostTime == nil {
                state.rateProbeFirstHostTime = chunk.hostTime
            }
            state.rateProbeFrames += chunk.frameCount
            let elapsed = Self.hostTimeToSeconds(chunk.hostTime &- (state.rateProbeFirstHostTime ?? chunk.hostTime))
            if elapsed >= Self.effectiveRateCheckWindowSeconds {
                state.rateChecked = true
                let effectiveRate = Double(state.rateProbeFrames) / elapsed
                if abs(effectiveRate - chunk.sampleRate) / chunk.sampleRate > Self.effectiveRateToleranceFraction {
                    triggerRebuild(state: state)
                }
            }
        }

        guard state.alignmentResolved else {
            if state.firstSystemHostTime == nil {
                state.firstSystemHostTime = chunk.hostTime
            }
            state.heldSystemChunks.append(chunk)
            resolveAlignmentIfPossible(state: state, mixer: mixer)
            return
        }
        ingestSystem(chunk, mixer: mixer)
    }

    private func processMicChunk(_ chunk: RawAudioChunk, mixer: AudioMixer, state: ConsumerAlignmentState) {
        guard state.alignmentResolved else {
            if state.firstMicHostTime == nil {
                state.firstMicHostTime = chunk.hostTime
            }
            state.heldMicChunks.append(chunk)
            resolveAlignmentIfPossible(state: state, mixer: mixer)
            return
        }
        ingestMic(chunk, mixer: mixer)
    }

    /// A rebuild starts a fresh tap epoch whose host times aren't
    /// comparable to the old epoch's, so the effective-rate probe's
    /// baseline is reset here and re-establishes itself from the next
    /// chunk onward.
    private func triggerRebuild(state: ConsumerAlignmentState) {
        state.resetRateProbe()
        try? systemAudioSource.rebuild()
    }

    /// Waits until the first chunk from every side that will ever deliver
    /// one has arrived, then primes whichever side started later with
    /// exactly the leading silence needed to align both streams by host
    /// time rather than by raw buffered-sample-count parity — a fixed
    /// startup offset, not continuous drift correction (the aggregate
    /// device's own drift compensation, see `ProcessTapSource`, covers
    /// the system side's clock over a long meeting).
    private func resolveAlignmentIfPossible(state: ConsumerAlignmentState, mixer: AudioMixer) {
        guard !state.alignmentResolved else { return }
        let micReady = !state.micIncluded || state.firstMicHostTime != nil
        let systemReady = state.firstSystemHostTime != nil
        let forced = state.heldSystemChunks.count + state.heldMicChunks.count > Self.maxHeldAlignmentChunks
        guard (micReady && systemReady) || forced else { return }

        if state.micIncluded, let systemHostTime = state.firstSystemHostTime, let micHostTime = state.firstMicHostTime {
            if systemHostTime < micHostTime {
                let lagFrames = Int(Self.hostTimeToSeconds(micHostTime - systemHostTime) * Double(AudioImporter.sampleRate))
                mixer.primeMicLeadIn(frames: lagFrames)
            } else if micHostTime < systemHostTime {
                let lagFrames = Int(Self.hostTimeToSeconds(systemHostTime - micHostTime) * Double(AudioImporter.sampleRate))
                mixer.primeSystemLeadIn(frames: lagFrames)
            }
        }

        state.alignmentResolved = true
        let heldSystem = state.heldSystemChunks
        let heldMic = state.heldMicChunks
        state.heldSystemChunks = []
        state.heldMicChunks = []
        for chunk in heldSystem {
            ingestSystem(chunk, mixer: mixer)
        }
        for chunk in heldMic {
            ingestMic(chunk, mixer: mixer)
        }
    }

    /// Drives the "no callback at all" rebuild trigger (a dead IOProc
    /// calls back zero times, not with zero-valued buffers, so
    /// `SystemAudioWatchdog.observeBuffer` alone can never see it).
    /// Re-arms `lastSystemActivity` after triggering, mirroring
    /// `observeBuffer`'s own "at most once per threshold" behavior.
    private func checkNoCallbackWatchdog(lastSystemActivity: inout ContinuousClock.Instant) {
        let elapsed = Self.seconds(ContinuousClock.now - lastSystemActivity)
        guard elapsed >= noCallbackThreshold else { return }
        lock.withLock { watchdog.observeNoCallback() }
        try? systemAudioSource.rebuild()
        lastSystemActivity = .now
    }

    private func ingestSystem(_ chunk: RawAudioChunk, mixer: AudioMixer) {
        guard let buffer = Self.makeBuffer(from: chunk) else { return }
        do {
            try mixer.ingestSystem(buffer)
        } catch {
            Self.log.error("system audio chunk dropped", ["reason": .sensitive(String(describing: error))])
        }
    }

    private func ingestMic(_ chunk: RawAudioChunk, mixer: AudioMixer) {
        guard let buffer = Self.makeBuffer(from: chunk) else { return }
        do {
            try mixer.ingestMic(buffer)
        } catch {
            Self.log.error("mic audio chunk dropped", ["reason": .sensitive(String(describing: error))])
        }
    }

    /// Reconstructs an `AVAudioPCMBuffer` from a drained chunk — an
    /// allocation, safe here since this runs only on the consumer task,
    /// never on the real-time callback thread that produced the chunk.
    private static func makeBuffer(from chunk: RawAudioChunk) -> AVAudioPCMBuffer? {
        guard
            chunk.frameCount > 0, chunk.channelCount > 0,
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: chunk.sampleRate, channels: AVAudioChannelCount(chunk.channelCount), interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frameCount)),
            let channelData = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        chunk.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for channel in 0 ..< chunk.channelCount {
                channelData[channel].update(from: base.advanced(by: channel * chunk.frameCount), count: chunk.frameCount)
            }
        }
        return buffer
    }

    private func runningComponents() -> (AudioMixer, CaptureAudioWriting)? {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .running, .stopping:
            guard let mixer, let writer else { return nil }
            return (mixer, writer)
        default:
            return nil
        }
    }

    private static func hostTimeToSeconds(_ ticks: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(ticks)) / 1_000_000_000
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Story 5.8's onboarding trigger: there is no public API to check or
/// request the "System Audio Recording" TCC grant (research.md), so the
/// only way to surface the OS's prompt is to actually run a tap briefly.
public enum SystemAudioPermissionProbe {
    /// Runs `source` for one second and discards every buffer — purely so
    /// macOS shows the System Audio Recording prompt the first time this
    /// runs, for onboarding to trigger ahead of the first real capture.
    public static func prompt(source: SystemAudioSource = ProcessTapSource()) async throws {
        try source.start()
        defer { source.stop() }
        try await Task.sleep(for: .seconds(1))
    }
}
