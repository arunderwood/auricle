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
    var rateProbeFirstHostTime: UInt64?
    var rateProbeFrames = 0
    var rateChecked = false

    init(micIncluded: Bool) {
        self.micIncluded = micIncluded
        alignmentResolved = !micIncluded
    }

    /// A rebuild starts a fresh tap epoch whose host times aren't
    /// comparable to the old epoch's, so the effective-rate probe's
    /// baseline must be re-established from the next chunk onward.
    func resetRateProbe() {
        rateProbeFirstHostTime = nil
        rateProbeFrames = 0
        rateChecked = false
    }
}
