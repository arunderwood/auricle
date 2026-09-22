@testable import Capture
import Foundation
import Testing

struct ZeroBufferDetectorTests {
    @Test func aSilentChunkIsExactZero() {
        #expect(ZeroBufferDetector.isExactZero([Float](repeating: 0, count: 480)))
    }

    @Test func aToneChunkIsNotExactZero() {
        let samples = (0 ..< 480).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        #expect(!ZeroBufferDetector.isExactZero(samples))
    }

    @Test func aSingleNonZeroSampleDisqualifiesTheWholeChunk() {
        var samples = [Float](repeating: 0, count: 100)
        samples[99] = 0.0001
        #expect(!ZeroBufferDetector.isExactZero(samples))
    }

    @Test func anEmptyChunkCountsAsExactZero() {
        #expect(ZeroBufferDetector.isExactZero([]))
    }
}

/// Drives `SystemAudioWatchdog`'s two rebuild triggers directly with
/// synthetic data — the `ProcessTapSource`/`CaptureSession` machinery this
/// backs needs a live Mac (the zero-buffer/no-callback path) or a fake
/// `SystemAudioSource` (the consumer-loop wiring, in `CaptureSessionTests`)
/// to exercise end to end, but the rebuild decision itself is pure and
/// testable here.
struct SystemAudioWatchdogTests {
    @Test func fewerThanThirtyConsecutiveZeroSecondsNeverTriggersARebuild() {
        var watchdog = SystemAudioWatchdog()
        for _ in 0 ..< 29 {
            let triggered = watchdog.observeBuffer(isExactZero: true, duration: 1)
            #expect(!triggered)
        }
        #expect(watchdog.rebuildCount == 0)
        #expect(watchdog.exactZeroSeconds == 29)
    }

    @Test func exactlyThirtyConsecutiveZeroSecondsTriggersOneRebuild() {
        var watchdog = SystemAudioWatchdog()
        var rebuilds = 0
        for _ in 0 ..< 30 where watchdog.observeBuffer(isExactZero: true, duration: 1) {
            rebuilds += 1
        }
        #expect(rebuilds == 1)
        #expect(watchdog.rebuildCount == 1)
        #expect(watchdog.exactZeroSeconds == 30)
    }

    @Test func aNonZeroBufferResetsTheConsecutiveStreakWithoutLosingTheTotal() {
        var watchdog = SystemAudioWatchdog()
        for _ in 0 ..< 20 {
            _ = watchdog.observeBuffer(isExactZero: true, duration: 1)
        }
        let triggeredByReset = watchdog.observeBuffer(isExactZero: false, duration: 1)
        #expect(!triggeredByReset)
        // The streak reset; 20 more zero seconds (40 total) still isn't a
        // fresh 30-in-a-row.
        for _ in 0 ..< 20 {
            _ = watchdog.observeBuffer(isExactZero: true, duration: 1)
        }
        #expect(watchdog.rebuildCount == 0)
        #expect(watchdog.exactZeroSeconds == 40)
    }

    @Test func rebuildsAreCappedAtOncePerThirtyFreshConsecutiveSeconds() {
        var watchdog = SystemAudioWatchdog()
        var rebuilds = 0
        // 90 consecutive zero seconds should trigger exactly 3 rebuilds —
        // never more than once per 30s.
        for _ in 0 ..< 90 where watchdog.observeBuffer(isExactZero: true, duration: 1) {
            rebuilds += 1
        }
        #expect(rebuilds == 3)
        #expect(watchdog.rebuildCount == 3)
        #expect(watchdog.exactZeroSeconds == 90)
    }

    @Test func fractionalBufferDurationsAccumulateTowardTheThreshold() {
        var watchdog = SystemAudioWatchdog()
        var rebuilds = 0
        // 300 buffers of 0.1s each = 30s, matching real IOProc chunk sizes
        // far better than whole-second observations do.
        for _ in 0 ..< 300 where watchdog.observeBuffer(isExactZero: true, duration: 0.1) {
            rebuilds += 1
        }
        #expect(rebuilds == 1)
        #expect(abs(watchdog.exactZeroSeconds - 30) < 0.0001)
    }

    @Test func aQuietMeetingAndAMissingGrantAreIndistinguishableToTheWatchdog() {
        // research.md: an all-zero buffer is ambiguous between a missing
        // TCC grant and genuine silence. The watchdog treats both
        // identically — that's the point of never failing the capture here.
        var watchdog = SystemAudioWatchdog()
        for _ in 0 ..< 30 {
            _ = watchdog.observeBuffer(isExactZero: true, duration: 1)
        }
        #expect(watchdog.rebuildCount == 1)
    }

    @Test func noCallbackAtAllCountsAsARebuildTrigger() {
        // A dead IOProc (the aggregate device's output device removed or
        // changed) calls back zero times, not with zero-valued buffers —
        // the caller (CaptureSession's consumer timer) is what decides
        // *when* enough silence-from-absence has passed; this only tracks
        // the resulting counter.
        var watchdog = SystemAudioWatchdog()
        watchdog.observeNoCallback()
        #expect(watchdog.rebuildCount == 1)
        watchdog.observeNoCallback()
        #expect(watchdog.rebuildCount == 2)
    }
}
