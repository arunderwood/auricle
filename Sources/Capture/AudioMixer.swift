import AVFoundation
import Core
import Foundation

/// Resamples microphone and system-audio buffers to mono 16 kHz and sums
/// them into the one PCM16 stream `WAVWriter.write(_:)` consumes (Decision
/// 1.4's capture format). Each side gets its own `AVAudioConverter` and
/// accumulation buffer, built lazily from the format of that side's first
/// buffer: the mic and the system tap deliver buffers on independent clocks
/// and at independent chunk sizes (and a watchdog rebuild can hand the
/// system side a new format mid-capture), so nothing here assumes either
/// format up front.
///
/// `@unchecked Sendable`: every mutable field is touched only while `lock`
/// is held, which is what lets the mic-tap callback and the system-tap
/// callback call in concurrently without corrupting either pipeline.
public final class AudioMixer: @unchecked Sendable {
    /// How far behind (in already-resampled 16kHz frames, i.e. 2 seconds)
    /// one side can fall before `drain()` stops waiting for it and pads it
    /// with silence instead — bounds both the memory a stalled side can
    /// accumulate and how much audio a crash before `stop()` could lose.
    private static let maxStarvationFrames = AudioImporter.sampleRate * 2

    private let lock = NSLock()
    private var micPipeline: SourcePipeline?
    private var systemPipeline: SourcePipeline?

    public init() {}

    /// Feeds a buffer from the microphone. A no-op is impossible to express
    /// here — the mic-denied path (AC's mic-denied scenario) is simply
    /// `CaptureSession` never calling this at all, so `micPipeline` never
    /// gets built and every `drain()`/`flush()` mixes system audio alone.
    public func ingestMic(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        if micPipeline == nil || micPipeline?.sourceFormat != buffer.format {
            micPipeline = try SourcePipeline(sourceFormat: buffer.format, carryOver: micPipeline?.buffered ?? [])
        }
        try micPipeline?.append(buffer)
    }

    /// Feeds a buffer from `SystemAudioSource`.
    public func ingestSystem(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        if systemPipeline == nil || systemPipeline?.sourceFormat != buffer.format {
            systemPipeline = try SourcePipeline(sourceFormat: buffer.format, carryOver: systemPipeline?.buffered ?? [])
        }
        try systemPipeline?.append(buffer)
    }

    /// Mixes and removes whatever whole frames every side currently
    /// converted has buffered, as mono 16-bit PCM ready for
    /// `WAVWriter.write(_:)`. A side that has been ingested from before but
    /// is momentarily starved holds the other side back rather than being
    /// treated as silence — unlike `flush()`, more is still coming — unless
    /// the gap has grown past `maxStarvationFrames`, at which point the
    /// starved side is padded with silence the same way `flush()` pads it,
    /// so a stalled mic or a system tap that hasn't delivered yet can't
    /// grow this buffer without bound. A side that has *never* been
    /// ingested from (the mic-denied path) is not waited on at all, since
    /// nothing will ever arrive for it. Returns empty `Data` when nothing
    /// is ready yet; callers just call again after the next `ingest`.
    public func drain() -> Data {
        lock.lock()
        defer { lock.unlock() }

        let systemFrames = systemPipeline?.buffered.count ?? 0
        let micFrames = micPipeline?.buffered.count
        let smallerFrames = min(systemFrames, micFrames ?? systemFrames)
        let largerFrames = max(systemFrames, micFrames ?? 0)
        let frameCount = (largerFrames - smallerFrames > Self.maxStarvationFrames) ? largerFrames : smallerFrames
        guard frameCount > 0 else { return Data() }

        let system = systemPipeline?.take(min(frameCount, systemFrames)) ?? []
        let mic = micPipeline?.take(min(frameCount, micFrames ?? 0))
        return Self.mix(system: system, mic: mic, frameCount: frameCount)
    }

    /// Mixes and removes every remaining buffered frame from every side, at
    /// `stop()`. Unlike `drain()`, a side with fewer buffered frames than
    /// the other is padded with silence rather than held back — nothing
    /// will ever top it up again once capture has stopped.
    public func flush() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let data = peekFlushLocked()
        commitFlushLocked()
        return data
    }

    /// The bytes `flush()` would produce right now, without removing
    /// anything from either pipeline — lets a caller attempt to write them
    /// out first and only call `discardFlushed()` once that succeeds, so a
    /// write failure leaves every sample still buffered instead of
    /// silently discarding audio that was never actually written.
    public func peekFlush() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return peekFlushLocked()
    }

    /// Removes exactly the frames `peekFlush()` last reported. Call only
    /// after successfully writing them out.
    public func discardFlushed() {
        lock.lock()
        defer { lock.unlock() }
        commitFlushLocked()
    }

    private func peekFlushLocked() -> Data {
        let systemFrames = systemPipeline?.buffered.count ?? 0
        let micFrames = micPipeline?.buffered.count ?? 0
        let frameCount = max(systemFrames, micFrames)
        guard frameCount > 0 else { return Data() }

        let system = Array(systemPipeline?.buffered.prefix(systemFrames) ?? [])
        let mic = micPipeline.map { Array($0.buffered.prefix(micFrames)) }
        return Self.mix(system: system, mic: mic, frameCount: frameCount)
    }

    private func commitFlushLocked() {
        let systemFrames = systemPipeline?.buffered.count ?? 0
        let micFrames = micPipeline?.buffered.count ?? 0
        _ = systemPipeline?.take(systemFrames)
        _ = micPipeline?.take(micFrames)
    }

    /// Sums the two sides sample-by-sample, hard-clamping to the
    /// normalized range before quantizing to 16-bit — simple summing mixes
    /// rather than averaging, since a quiet single-source stretch (system
    /// audio while no one is talking) must not come out at half volume.
    /// A source shorter than `frameCount` is padded with silence for the
    /// remainder, which is what makes `flush()`'s tail-padding behavior
    /// possible without a second code path.
    private static func mix(system: [Float], mic: [Float]?, frameCount: Int) -> Data {
        var pcm = Data(capacity: frameCount * 2)
        for index in 0 ..< frameCount {
            let systemSample = index < system.count ? system[index] : 0
            let micSample: Float = if let mic, index < mic.count {
                mic[index]
            } else {
                0
            }
            let mixed = max(-1, min(1, systemSample + micSample))
            let sample = Int16((mixed * Float(Int16.max)).rounded())
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }
}

/// One source's resample-to-16kHz-mono-Float32 pipeline, plus the samples
/// it has produced that the other source hasn't been mixed with yet.
private final class SourcePipeline {
    let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private(set) var buffered: [Float] = []

    /// `carryOver` is the predecessor pipeline's still-unmixed `buffered`
    /// samples — already resampled to the fixed 16kHz mono target, so they
    /// need no reconversion. A format change (typically a `ProcessTapSource`
    /// watchdog rebuild handing back a new tap format) replaces the
    /// converter but must not discard audio that was already converted and
    /// is simply waiting for `drain()`/`flush()` to mix it.
    init(sourceFormat: AVAudioFormat, carryOver: [Float] = []) throws {
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(AudioImporter.sampleRate),
                channels: 1,
                interleaved: false,
            ),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            throw CaptureError.streamInterrupted(reason: "could not build a 16kHz mono converter for \(sourceFormat)")
        }
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
        buffered = carryOver
    }

    /// Converts `buffer` and appends the result. The converter is reused
    /// across calls, so its internal resampling state — including samples
    /// it read but hasn't emitted yet — carries forward correctly between
    /// buffers rather than resetting every call.
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else {
            throw CaptureError.streamInterrupted(reason: "buffer has a non-positive or non-finite sample rate (\(buffer.format.sampleRate))")
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw CaptureError.streamInterrupted(reason: "could not allocate a conversion buffer")
        }

        let source = SingleBufferSource(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let next = source.next() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        guard status != .error else {
            let reason = conversionError.map { "resample failed: \($0.localizedDescription)" } ?? "resample failed"
            throw CaptureError.streamInterrupted(reason: reason)
        }

        guard let channel = output.floatChannelData else { return }
        buffered.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// Removes and returns the first `count` buffered frames, keeping the
    /// rest for the next `drain()`/`flush()`.
    func take(_ count: Int) -> [Float] {
        let taken = Array(buffered.prefix(count))
        buffered.removeFirst(count)
        return taken
    }
}

/// Feeds `AVAudioConverter` a single buffer then reports end-of-stream. A
/// class (mirroring `AudioImporter.Reader`) because the converter's input
/// callback is `@Sendable` and cannot capture a mutable local directly; the
/// callback runs synchronously inside `convert`, so nothing here is
/// actually shared across threads.
private final class SingleBufferSource: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next() -> AVAudioPCMBuffer? {
        guard !consumed else { return nil }
        consumed = true
        return buffer
    }
}
