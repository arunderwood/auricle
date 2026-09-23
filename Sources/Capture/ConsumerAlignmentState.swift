import Foundation

/// Per-capture state for `CaptureSession`'s consumer loop: stream
/// alignment (holding each side's early chunks until both sides' first
/// host time is known, so the later starter can be primed with the right
/// amount of leading silence) and the effective-sample-rate probe. A plain
/// class rather than fields on `CaptureSession` itself: it's only ever
/// touched from the one `Task` that owns it.
final class ConsumerAlignmentState {
    let micIncluded: Bool
    var alignmentResolved: Bool
    var firstSystemHostTime: UInt64?
    var firstMicHostTime: UInt64?
    var heldSystemChunks: [RawAudioChunk] = []
    var heldMicChunks: [RawAudioChunk] = []
    /// The first and most recently observed (host time, sample time) pair
    /// from the current tap epoch's system chunks — the effective-rate
    /// probe's window. `sampleTime` advances by exactly each chunk's frame
    /// count every callback, so the ratio of its delta to the matching
    /// `hostTime` delta gives the producer's actual sample rate without
    /// the rounding error a per-chunk frame-count sum has.
    var rateProbeFirstHostTime: UInt64?
    var rateProbeFirstSampleTime: Double?
    var rateProbeLastHostTime: UInt64?
    var rateProbeLastSampleTime: Double?
    var rateChecked = false
    /// Set once the effective-rate probe finds the tap's declared rate
    /// disagrees with the measured one — the rate every subsequent system
    /// chunk's buffer is built at instead of its own declared
    /// `sampleRate`, until the next rebuild starts a fresh epoch.
    var correctedSystemSampleRate: Double?
    /// The `RawAudioChunk.sourceEpoch` this state's rate probe and
    /// correction were established against. `nil` before any system chunk
    /// has arrived. Compared against every new chunk's own `sourceEpoch`
    /// so a rebuild — from any trigger, not only the ones that happen to
    /// call `resetRateProbe()` directly — is detected and the stale probe
    /// state reset before it mixes two epochs' `sampleTime`/`hostTime`
    /// counters or applies a correction measured on hardware the current
    /// epoch no longer uses.
    var currentSystemEpoch: Int?

    init(micIncluded: Bool) {
        self.micIncluded = micIncluded
        alignmentResolved = !micIncluded
    }

    /// A rebuild starts a fresh tap epoch whose host times aren't
    /// comparable to the old epoch's, so the effective-rate probe's
    /// baseline and any correction from the previous epoch must be
    /// re-established from the next chunk onward.
    func resetRateProbe() {
        rateProbeFirstHostTime = nil
        rateProbeFirstSampleTime = nil
        rateProbeLastHostTime = nil
        rateProbeLastSampleTime = nil
        rateChecked = false
        correctedSystemSampleRate = nil
    }
}
