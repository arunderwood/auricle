import Foundation

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
    /// than decided internally, since the watchdog now runs on the
    /// consumer side, off the real-time callback thread. A no-op if
    /// `start()` hasn't been called, or after `stop()`.
    func rebuild() throws
}
