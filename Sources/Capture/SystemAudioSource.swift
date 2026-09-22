import AVFoundation
import Foundation

/// Story 5.4's rebuild/zero-buffer counters, read out of a running
/// `SystemAudioSource` for capture metadata. `Sendable` and `Equatable` so a
/// snapshot can cross the tap's own callback thread and be asserted on
/// directly in tests.
public struct SystemAudioWatchdogStats: Sendable, Equatable {
    public var exactZeroSeconds: Double
    public var rebuildCount: Int

    public init(exactZeroSeconds: Double = 0, rebuildCount: Int = 0) {
        self.exactZeroSeconds = exactZeroSeconds
        self.rebuildCount = rebuildCount
    }
}

/// The seam behind system-audio capture (Decision 1.4's reversibility
/// hedge, research.md's recommendation): `ProcessTapSource` is the one
/// conformance today, backed by a Core Audio global process tap. A future
/// ScreenCaptureKit backend — the fallback if the live-app check ever fails
/// — drops in here without `AudioMixer`, `WAVWriter` or `CaptureStage`
/// changing at all.
public protocol SystemAudioSource: AnyObject, Sendable {
    /// Starts delivering system-audio buffers to `onBuffer` until `stop()`
    /// is called. Each delivered buffer carries its own `AVAudioFormat`,
    /// since a watchdog rebuild can hand back a buffer at a different
    /// sample rate than the one `start()` began with.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws

    /// Tears down the underlying capture (tap/aggregate/IOProc for
    /// `ProcessTapSource`). Idempotent: a call before `start()`, or a
    /// second call after a prior `stop()`, is a no-op.
    func stop()

    /// A snapshot of the exact-zero-seconds/rebuild counters observed so
    /// far, for Story 5.4's capture metadata to read once it exists.
    var watchdogStats: SystemAudioWatchdogStats { get }
}
