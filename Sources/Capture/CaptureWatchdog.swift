import Foundation

/// A snapshot of `CaptureSession`'s system-audio watchdog counters, for
/// Story 5.4's capture metadata to read once it exists.
public struct CaptureWatchdogStats: Sendable, Equatable {
    public let exactZeroSeconds: Double
    public let rebuildCount: Int
    /// How many times the effective-sample-rate check found the tap's
    /// declared rate didn't match what callback timestamps actually
    /// measured. Corrected by resampling at the measured rate rather than
    /// by rebuilding (a rebuild can't fix a tap that keeps reporting the
    /// same rate), so this counts corrections, not rebuilds.
    public let rateCorrectionCount: Int
    public let systemRingDroppedChunkCount: Int
    public let systemRingTruncatedChunkCount: Int
    public let micRingDroppedChunkCount: Int
    public let micRingTruncatedChunkCount: Int
    /// The first write failure `WAVWriter.write(_:)` raised during this
    /// capture, if any — `nil` means every write so far has succeeded.
    /// Rendered as a description rather than kept as a `CaptureError`
    /// since this struct is `Equatable` and `CaptureError` isn't.
    public let firstWriteErrorDescription: String?

    public init(
        exactZeroSeconds: Double = 0,
        rebuildCount: Int = 0,
        rateCorrectionCount: Int = 0,
        systemRingDroppedChunkCount: Int = 0,
        systemRingTruncatedChunkCount: Int = 0,
        micRingDroppedChunkCount: Int = 0,
        micRingTruncatedChunkCount: Int = 0,
        firstWriteErrorDescription: String? = nil,
    ) {
        self.exactZeroSeconds = exactZeroSeconds
        self.rebuildCount = rebuildCount
        self.rateCorrectionCount = rateCorrectionCount
        self.systemRingDroppedChunkCount = systemRingDroppedChunkCount
        self.systemRingTruncatedChunkCount = systemRingTruncatedChunkCount
        self.micRingDroppedChunkCount = micRingDroppedChunkCount
        self.micRingTruncatedChunkCount = micRingTruncatedChunkCount
        self.firstWriteErrorDescription = firstWriteErrorDescription
    }
}

/// Story 5.2's system-audio rebuild rules, as pure decision logic — kept
/// separate from `ProcessTapSource`/`CaptureSession` so tests can drive it
/// directly with synthetic data, since a real Core Audio tap needs a live
/// Mac to exercise. Driven entirely from `CaptureSession`'s consumer task,
/// never from the real-time callback thread (NFR-P13): the callback only
/// copies raw samples into an `AudioRingBuffer`, and this type is fed from
/// what the consumer drains out of it.
///
/// Two independent triggers, sharing one `rebuildCount`:
/// - 30 consecutive seconds of exact-zero system-audio buffers. A
///   zero-buffer stretch is ambiguous with a quiet meeting or a missing
///   grant (research.md); this never fails the capture, it only decides
///   when a rebuild is due.
/// - No callback at all for `noCallbackRebuildThreshold` seconds. A dead
///   IOProc (the aggregate device's output device removed or changed)
///   calls back zero times, not with zero-valued buffers, so the
///   zero-buffer trigger alone can never see it.
struct SystemAudioWatchdog: Sendable, Equatable {
    static let zeroBufferRebuildThreshold: Double = 30
    static let noCallbackRebuildThreshold: Double = 5

    private(set) var exactZeroSeconds: Double = 0
    private(set) var rebuildCount: Int = 0
    private(set) var rateCorrectionCount: Int = 0
    private var consecutiveZeroSeconds: Double = 0

    /// `duration` is the wall-clock length of the buffer just observed;
    /// `isExactZero` is whether every sample in it was exactly zero.
    /// Returns whether a rebuild is due right now — true only the instant
    /// the running zero streak crosses the threshold, and the streak
    /// resets immediately after so the next rebuild needs its own fresh
    /// 30 consecutive seconds.
    mutating func observeBuffer(isExactZero: Bool, duration: Double) -> Bool {
        guard isExactZero else {
            consecutiveZeroSeconds = 0
            return false
        }
        consecutiveZeroSeconds += duration
        exactZeroSeconds += duration
        guard consecutiveZeroSeconds >= Self.zeroBufferRebuildThreshold else { return false }
        consecutiveZeroSeconds = 0
        rebuildCount += 1
        return true
    }

    /// Called by the consumer's timer once it notices no chunk has
    /// arrived for `noCallbackRebuildThreshold` seconds. The caller is
    /// responsible for not calling this again until another full
    /// threshold's worth of continued silence has passed (mirroring
    /// `observeBuffer`'s own "at most once per threshold" behavior) —
    /// this type has no wall clock of its own to enforce that itself.
    mutating func observeNoCallback() {
        consecutiveZeroSeconds = 0
        rebuildCount += 1
    }

    /// Called once per tap epoch when the effective-rate check finds the
    /// tap's declared rate disagrees with what callback timestamps
    /// measured. Counts the correction; does not touch `rebuildCount`,
    /// because this trigger resamples at the measured rate instead of
    /// requesting a rebuild.
    mutating func observeRateCorrection() {
        rateCorrectionCount += 1
    }
}

/// Whether every sample in a chunk is exactly zero — the shape both a
/// missing System Audio Recording grant and a genuinely silent stretch of
/// the meeting produce (research.md's "any-zero-buffer ambiguity"), which
/// is exactly why `SystemAudioWatchdog` treats it as a rebuild trigger
/// rather than a failure.
enum ZeroBufferDetector {
    static func isExactZero(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        return samples.allSatisfy { $0 == 0 }
    }
}
