import Foundation

/// How many chunks a `SystemAudioSource`'s internal ring has dropped
/// (arrived while the ring was full) or truncated (arrived larger than one
/// slot's fixed capacity) since capture began — visibility into data loss
/// that would otherwise be silent, since a real-time producer can neither
/// log nor block to report it (NFR-P13). Exposed for `CaptureSession`'s
/// capture metadata (Story 5.4's `CaptureMeta`) to surface.
public struct RingLossStats: Sendable, Equatable {
    public let droppedChunkCount: Int
    public let truncatedChunkCount: Int

    public init(droppedChunkCount: Int = 0, truncatedChunkCount: Int = 0) {
        self.droppedChunkCount = droppedChunkCount
        self.truncatedChunkCount = truncatedChunkCount
    }
}

/// The seam behind system-audio capture (Decision 1.4's reversibility
/// hedge, research.md's recommendation): `ProcessTapSource` is the one
/// conformance today, backed by a Core Audio global process tap. A future
/// ScreenCaptureKit backend — the fallback if the live-app check ever fails
/// — drops in here without `AudioMixer`, `WAVWriter` or `CaptureSession`
/// changing at all.
///
/// Buffers are pulled, not pushed: `start()` begins capturing into the
/// conformance's own internal ring buffer, and `drain(_:)` is how a
/// consumer retrieves what's accumulated. This (rather than a per-buffer
/// `AVAudioPCMBuffer` callback) is what keeps every real-time-thread
/// concern — allocation, locking, resampling, I/O — entirely inside the
/// conformance and off whatever thread the consumer runs on (NFR-P13).
public protocol SystemAudioSource: AnyObject, Sendable {
    /// Starts capturing into this source's internal ring buffer.
    func start() throws

    /// Tears down the underlying capture (tap/aggregate/IOProc for
    /// `ProcessTapSource`). Idempotent: a call before `start()`, or a
    /// second call after a prior `stop()`, is a no-op.
    func stop()

    /// Removes and hands every currently available raw audio chunk to
    /// `consume`, oldest first. Call only from one consumer thread/task at
    /// a time; safe to call from a different thread than `start()`/`stop()`.
    func drain(_ consume: (RawAudioChunk) -> Void)

    /// Tears down and rebuilds the underlying capture with fresh state.
    /// Externally triggered by the consumer's watchdog (30s of exact-zero
    /// buffers, no callback at all for 5s, a tap/output-device format
    /// change, or an observed-vs-declared sample-rate mismatch) rather
    /// than decided internally, since the watchdog runs on the consumer
    /// side, off the real-time callback thread, not inside this protocol's
    /// conformances. A no-op if `start()` hasn't been called, or after
    /// `stop()`. Concurrent calls (e.g. two property listeners firing for
    /// one hardware event) must serialize against each other rather than
    /// each independently tearing down and rebuilding.
    func rebuild() throws

    /// A snapshot of this source's internal ring's drop/truncation
    /// counters, for `CaptureSession`'s capture metadata to read.
    var ringLossStats: RingLossStats { get }
}
