import Foundation
import os

/// A chunk of raw audio handed from a real-time producer (`ProcessTapSource`'s
/// IOProc, `CaptureSession`'s mic tap) to a consumer, off that real-time
/// thread: `AudioRingBuffer.drainAll(_:)` is the one place this is built,
/// and it never runs on the callback thread itself. `samples` is
/// channel-major: channel `c`'s frames run from `c * frameCount` to
/// `(c + 1) * frameCount`.
public struct RawAudioChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int
    /// The `AudioTimeStamp.mHostTime` (system tap) or `AVAudioTime.hostTime`
    /// (mic) this chunk's first frame was captured at — the common clock
    /// `CaptureSession` aligns the two streams by, rather than by raw
    /// buffered-sample-count parity (Decision: two independent hardware
    /// clocks start at different moments).
    public let hostTime: UInt64
    /// The producer's running sample counter (`AudioTimeStamp.mSampleTime`
    /// for the system tap, `AVAudioTime.sampleTime` for the mic) at this
    /// chunk's first frame — advances by exactly `frameCount` every
    /// callback, unlike `hostTime`'s wall-clock ticks. `CaptureSession`'s
    /// effective-rate check divides a `sampleTime` delta by the matching
    /// `hostTime` delta to measure the producer's actual sample rate
    /// without any per-chunk rounding error. Defaults to 0 for a caller
    /// that has no sample-time source to report.
    public let sampleTime: Double

    public init(samples: [Float], sampleRate: Double, channelCount: Int, frameCount: Int, hostTime: UInt64, sampleTime: Double = 0) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.hostTime = hostTime
        self.sampleTime = sampleTime
    }
}

/// A fixed-capacity single-producer/single-consumer ring of raw audio
/// frames, used to move samples off a real-time audio callback thread
/// without that thread ever allocating, blocking on meaningful contention,
/// or doing I/O — NFR-P13's "no perceivable latency" requirement. Every
/// slot's backing storage is allocated once at `init`; nothing here
/// allocates again after that (`drainAll`'s `RawAudioChunk` construction
/// is the one exception, and it runs only on the consumer side).
///
/// `os_unfair_lock` guards only the fixed-size memcpy plus index update in
/// `publish`/`peekNext`/`freeNext` — true single-producer/single-consumer
/// contention over a bounded, sub-microsecond critical section (one slot's
/// worth of samples, capped at construction), not the kind of hold time
/// NFR-P13 is worried about. Disk I/O, resampling, mixing, and logging
/// happen only in the consumer, never here.
final class AudioRingBuffer: @unchecked Sendable {
    struct Slot: Sendable {
        var sampleRate: Double = 0
        var channelCount: Int = 0
        var frameCount: Int = 0
        var hostTime: UInt64 = 0
        var sampleTime: Double = 0
    }

    /// How many chunks `publish` has dropped (the ring was full) or
    /// truncated (the chunk was larger than one slot's fixed capacity)
    /// since this ring was created. Guarded by `unfairLock` alongside the
    /// index state it's updated next to.
    struct DropStats: Sendable, Equatable {
        var droppedChunkCount = 0
        var truncatedChunkCount = 0
    }

    private let slotCapacityFrames: Int
    private let maxChannels: Int
    private let slotCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let metadata: UnsafeMutablePointer<Slot>

    private var unfairLock = os_unfair_lock()
    private var writeIndex = 0
    private var readIndex = 0
    private var count = 0
    /// Read/written only under `unfairLock`. What `secondsSinceLastPublish`
    /// reads to answer "has the producer stopped calling back entirely" —
    /// distinct from a slot arriving that happens to be all zero.
    private var lastPublishHostTime: UInt64 = 0
    private var dropStats = DropStats()

    init(slotCount: Int, slotCapacityFrames: Int, maxChannels: Int) {
        precondition(slotCount > 0 && slotCapacityFrames > 0 && maxChannels > 0)
        self.slotCount = slotCount
        self.slotCapacityFrames = slotCapacityFrames
        self.maxChannels = maxChannels
        let totalSamples = slotCount * slotCapacityFrames * maxChannels
        samples = .allocate(capacity: totalSamples)
        samples.initialize(repeating: 0, count: totalSamples)
        metadata = .allocate(capacity: slotCount)
        metadata.initialize(repeating: Slot(), count: slotCount)
    }

    deinit {
        samples.deallocate()
        metadata.deallocate()
    }

    /// Producer-only (the real-time callback). `channelData[c]` must have
    /// at least `frameCount` valid samples for each `c < channelCount`.
    /// Silently drops the chunk if the ring is full, or truncates it to
    /// `slotCapacityFrames` if it's larger than one slot's fixed capacity
    /// — logging or throwing here would itself violate the real-time
    /// constraint this type exists to uphold; `dropStats` is what a
    /// consumer reads instead. `AudioMixer`'s starvation padding and
    /// `secondsSinceLastPublish`'s "no callback" signal are what a caller
    /// also watches.
    func publish(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Double,
        hostTime: UInt64,
        sampleTime: Double = 0,
    ) {
        guard channelCount > 0, channelCount <= maxChannels, frameCount > 0 else { return }
        let framesToCopy = min(frameCount, slotCapacityFrames)

        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        lastPublishHostTime = hostTime
        if frameCount > slotCapacityFrames {
            dropStats.truncatedChunkCount += 1
        }
        guard count < slotCount else {
            dropStats.droppedChunkCount += 1
            return
        }

        let slot = writeIndex
        let base = samples.advanced(by: slot * slotCapacityFrames * maxChannels)
        for channel in 0 ..< channelCount {
            base.advanced(by: channel * slotCapacityFrames).update(from: channelData[channel], count: framesToCopy)
        }
        metadata[slot] = Slot(sampleRate: sampleRate, channelCount: channelCount, frameCount: framesToCopy, hostTime: hostTime, sampleTime: sampleTime)
        writeIndex = (writeIndex + 1) % slotCount
        count += 1
    }

    /// Consumer-only. The oldest published slot's metadata and a pointer
    /// to its channel-major raw samples, without freeing it — call
    /// `freeNext()` once fully done reading, which is what lets the
    /// producer reuse that slot. `nil` when nothing is published yet.
    private func peekNext() -> (Slot, UnsafePointer<Float>)? {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        guard count > 0 else { return nil }
        let meta = metadata[readIndex]
        let base = UnsafePointer(samples.advanced(by: readIndex * slotCapacityFrames * maxChannels))
        return (meta, base)
    }

    /// Consumer-only. Frees the slot `peekNext()` last returned.
    private func freeNext() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        guard count > 0 else { return }
        readIndex = (readIndex + 1) % slotCount
        count -= 1
    }

    /// Consumer-only: hands every currently published chunk to `consume`,
    /// oldest first, copying each one out of ring storage into a fresh
    /// `RawAudioChunk` (an allocation, safe here since this never runs on
    /// the real-time callback thread) and freeing its slot immediately
    /// after.
    func drainAll(_ consume: (RawAudioChunk) -> Void) {
        while let (meta, pointer) = peekNext() {
            var flat = [Float](repeating: 0, count: meta.channelCount * meta.frameCount)
            flat.withUnsafeMutableBufferPointer { dest in
                guard let base = dest.baseAddress else { return }
                for channel in 0 ..< meta.channelCount {
                    base.advanced(by: channel * meta.frameCount)
                        .update(from: pointer.advanced(by: channel * slotCapacityFrames), count: meta.frameCount)
                }
            }
            freeNext()
            consume(RawAudioChunk(
                samples: flat, sampleRate: meta.sampleRate, channelCount: meta.channelCount,
                frameCount: meta.frameCount, hostTime: meta.hostTime, sampleTime: meta.sampleTime,
            ))
        }
    }

    /// Consumer-only: how long it's been since the last successful
    /// `publish`, even if every published buffer was silence — this is
    /// what distinguishes "the tap is alive but the meeting is quiet"
    /// from "the tap stopped calling back entirely" (a dead IOProc calls
    /// back zero times, not with zero-valued buffers, so the zero-buffer
    /// watchdog alone can't see it). Returns 0 before the first publish.
    func secondsSinceLastPublish(now: UInt64, hostTicksToSeconds: (UInt64) -> Double) -> Double {
        os_unfair_lock_lock(&unfairLock)
        let last = lastPublishHostTime
        os_unfair_lock_unlock(&unfairLock)
        guard last > 0, now > last else { return 0 }
        return hostTicksToSeconds(now - last)
    }

    /// Consumer-only: the running drop/truncation counts since this ring
    /// was created.
    func snapshotDropStats() -> DropStats {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return dropStats
    }
}
