import AVFoundation
import Core
import CoreAudio
import Foundation

/// The consumer side of `CaptureSession`'s real-time design (see the
/// type's own doc comment): everything here runs on the background `Task`
/// `start()` launches, never on the mic-tap or IOProc callback thread, so
/// it's free to allocate, lock, and do file I/O. A separate `extension`
/// (rather than more of the primary declaration) so the type's real-time
/// contract — what runs where — is visible in the file's own structure,
/// not just its comments.
extension CaptureSession {
    // MARK: - Consumer (off the real-time thread — see the type doc)

    func runConsumerLoop() async {
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
            do {
                try writer.write(pcm)
            } catch {
                recordFirstWriteError(error)
            }
        }
    }

    /// Records only the first write failure of the capture — later ones
    /// are the same underlying condition (e.g. a disk that's still full)
    /// repeating, not new information — and logs it once, off the
    /// real-time thread this method never runs on. `stop()` reports it by
    /// throwing after otherwise finishing normally, rather than losing it
    /// the way `try?` did.
    private func recordFirstWriteError(_ error: Error) {
        let captureError = (error as? CaptureError) ?? .streamInterrupted(reason: String(describing: error))
        let isFirst = lock.withLock {
            guard firstWriteError == nil else { return false }
            firstWriteError = captureError
            return true
        }
        guard isFirst else { return }
        Self.log.error("audio write failed; capture continuing with data loss", ["reason": .sensitive(String(describing: captureError))])
    }

    private func processSystemChunk(_ chunk: RawAudioChunk, mixer: AudioMixer, state: ConsumerAlignmentState) {
        let isZero = ZeroBufferDetector.isExactZero(chunk.samples)
        let duration = chunk.sampleRate > 0 ? Double(chunk.frameCount) / chunk.sampleRate : 0
        let shouldRebuild = lock.withLock { watchdog.observeBuffer(isExactZero: isZero, duration: duration) }
        if shouldRebuild {
            triggerRebuild(state: state)
        }

        checkEffectiveRate(chunk, state: state)

        guard state.alignmentResolved else {
            if state.firstSystemHostTime == nil {
                state.firstSystemHostTime = chunk.hostTime
            }
            state.heldSystemChunks.append(chunk)
            resolveAlignmentIfPossible(state: state, mixer: mixer)
            return
        }
        ingestSystem(chunk, mixer: mixer, state: state)
    }

    /// A stale or wrong declared rate (e.g. AirPods switching to HFP
    /// mid-call, or a mixdown tap that simply always reports 48kHz
    /// regardless of the system mix's real rate) would otherwise resample
    /// every subsequent buffer at the wrong ratio without ever erroring:
    /// once per tap epoch, over its first ~1 second of system audio,
    /// measures the arrival rate from the `sampleTime` delta between the
    /// epoch's first and most recent chunk over the matching `hostTime`
    /// delta, and compares it against the tap's declared rate.
    ///
    /// A disagreement is corrected by resampling at the measured rate for
    /// the rest of this epoch (`ingestSystem` passes
    /// `correctedSystemSampleRate` to `AVAudioFormat` instead of the
    /// chunk's own declared `sampleRate`), not by rebuilding: a tap that
    /// declares a fixed, wrong rate reports that same wrong rate again
    /// after a rebuild, so a rebuild cannot make this check start passing
    /// — only resampling at what the tap actually delivers can.
    private func checkEffectiveRate(_ chunk: RawAudioChunk, state: ConsumerAlignmentState) {
        guard !state.rateChecked, chunk.sampleRate > 0 else { return }
        if state.rateProbeFirstHostTime == nil {
            state.rateProbeFirstHostTime = chunk.hostTime
            state.rateProbeFirstSampleTime = chunk.sampleTime
        }
        state.rateProbeLastHostTime = chunk.hostTime
        state.rateProbeLastSampleTime = chunk.sampleTime

        guard
            let firstHostTime = state.rateProbeFirstHostTime, let firstSampleTime = state.rateProbeFirstSampleTime,
            let lastHostTime = state.rateProbeLastHostTime, let lastSampleTime = state.rateProbeLastSampleTime,
            lastHostTime > firstHostTime
        else { return }

        let elapsed = Self.hostTimeToSeconds(lastHostTime &- firstHostTime)
        guard elapsed >= Self.effectiveRateCheckWindowSeconds else { return }
        state.rateChecked = true
        let effectiveRate = (lastSampleTime - firstSampleTime) / elapsed
        guard effectiveRate > 0 else { return }
        if abs(effectiveRate - chunk.sampleRate) / chunk.sampleRate > Self.effectiveRateToleranceFraction {
            state.correctedSystemSampleRate = effectiveRate
            lock.withLock { watchdog.observeRateCorrection() }
        }
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

        // Both `hostTime`s are non-zero here: `ProcessTapSource` and
        // `publishMicBuffer` each drop a chunk rather than publish one
        // with an invalid host time, so a recorded `firstHostTime` is
        // always a real timestamp; the `> 0` guard and the `min` cap
        // below are a second line of defense, not load-bearing for a
        // correctly behaving producer.
        if state.micIncluded, let systemHostTime = state.firstSystemHostTime, let micHostTime = state.firstMicHostTime, systemHostTime > 0, micHostTime > 0 {
            if systemHostTime < micHostTime {
                let lagFrames = min(Int(Self.hostTimeToSeconds(micHostTime - systemHostTime) * Double(AudioImporter.sampleRate)), Self.maxLeadInFrames)
                mixer.primeMicLeadIn(frames: lagFrames)
            } else if micHostTime < systemHostTime {
                let lagFrames = min(Int(Self.hostTimeToSeconds(systemHostTime - micHostTime) * Double(AudioImporter.sampleRate)), Self.maxLeadInFrames)
                mixer.primeSystemLeadIn(frames: lagFrames)
            }
        }

        state.alignmentResolved = true
        let heldSystem = state.heldSystemChunks
        let heldMic = state.heldMicChunks
        state.heldSystemChunks = []
        state.heldMicChunks = []
        for chunk in heldSystem {
            ingestSystem(chunk, mixer: mixer, state: state)
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

    private func ingestSystem(_ chunk: RawAudioChunk, mixer: AudioMixer, state: ConsumerAlignmentState) {
        guard let buffer = Self.makeBuffer(from: chunk, sampleRateOverride: state.correctedSystemSampleRate) else { return }
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
    /// `sampleRateOverride`, when set, is used instead of the chunk's own
    /// declared `sampleRate` — how `checkEffectiveRate`'s correction
    /// reaches `AudioMixer`'s resampler without `AudioRingBuffer` or
    /// `RawAudioChunk` needing to know anything about it.
    private static func makeBuffer(from chunk: RawAudioChunk, sampleRateOverride: Double? = nil) -> AVAudioPCMBuffer? {
        let sampleRate = sampleRateOverride ?? chunk.sampleRate
        guard
            chunk.frameCount > 0, chunk.channelCount > 0,
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(chunk.channelCount), interleaved: false),
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
