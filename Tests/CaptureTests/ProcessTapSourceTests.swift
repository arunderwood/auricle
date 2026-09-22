import AVFoundation
@testable import Capture
import Foundation
import Testing

/// A mono Float32 buffer of `seconds`, either silent or a 440 Hz tone —
/// enough to drive `ZeroBufferDetector`/`ZeroBufferWatchdog` without a live
/// Core Audio tap, which needs a real Mac to exercise (Design Notes).
private func buffer(seconds: Double, sampleRate: Double = 48000, silent: Bool) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData)[0]
    for frame in 0 ..< Int(frames) {
        samples[frame] = silent ? 0 : Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
    }
    return buffer
}

struct ZeroBufferDetectorTests {
    @Test func aSilentBufferIsExactZero() throws {
        #expect(try ZeroBufferDetector.isExactZero(buffer(seconds: 0.1, silent: true)))
    }

    @Test func aToneBufferIsNotExactZero() throws {
        #expect(try !ZeroBufferDetector.isExactZero(buffer(seconds: 0.1, silent: false)))
    }

    @Test func aSingleNonZeroSampleDisqualifiesTheWholeBuffer() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        pcm.frameLength = 100
        let samples = try #require(pcm.floatChannelData)[0]
        for frame in 0 ..< 100 {
            samples[frame] = 0
        }
        samples[99] = 0.0001

        #expect(!ZeroBufferDetector.isExactZero(pcm))
    }

    @Test func aZeroLengthBufferCountsAsExactZero() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10))
        pcm.frameLength = 0

        #expect(ZeroBufferDetector.isExactZero(pcm))
    }
}

/// Drives `ZeroBufferWatchdog`'s "30 consecutive zero seconds ⇒ rebuild, at
/// most once per 30s" rule directly with synthetic durations — the
/// `ProcessTapSource` (`AudioHardwareCreateProcessTap` and friends) this
/// backs needs a live Mac to test end to end, but the rebuild decision
/// itself is pure and testable here.
struct ZeroBufferWatchdogTests {
    @Test func fewerThanThirtyConsecutiveZeroSecondsNeverTriggersARebuild() {
        var watchdog = ZeroBufferWatchdog()
        for _ in 0 ..< 29 {
            let triggered = watchdog.observe(isExactZero: true, duration: 1)
            #expect(!triggered)
        }
        #expect(watchdog.rebuildCount == 0)
        #expect(watchdog.exactZeroSeconds == 29)
    }

    @Test func exactlyThirtyConsecutiveZeroSecondsTriggersOneRebuild() {
        var watchdog = ZeroBufferWatchdog()
        var rebuilds = 0
        for _ in 0 ..< 30 where watchdog.observe(isExactZero: true, duration: 1) {
            rebuilds += 1
        }
        #expect(rebuilds == 1)
        #expect(watchdog.rebuildCount == 1)
        #expect(watchdog.exactZeroSeconds == 30)
    }

    @Test func aNonZeroBufferResetsTheConsecutiveStreakWithoutLosingTheTotal() {
        var watchdog = ZeroBufferWatchdog()
        for _ in 0 ..< 20 {
            _ = watchdog.observe(isExactZero: true, duration: 1)
        }
        let triggeredByReset = watchdog.observe(isExactZero: false, duration: 1)
        #expect(!triggeredByReset)
        // The streak reset; 20 more zero seconds (40 total) still isn't a
        // fresh 30-in-a-row.
        for _ in 0 ..< 20 {
            _ = watchdog.observe(isExactZero: true, duration: 1)
        }
        #expect(watchdog.rebuildCount == 0)
        #expect(watchdog.exactZeroSeconds == 40)
    }

    @Test func rebuildsAreCappedAtOncePerThirtyFreshConsecutiveSeconds() {
        var watchdog = ZeroBufferWatchdog()
        var rebuilds = 0
        // 90 consecutive zero seconds should trigger exactly 3 rebuilds —
        // never more than once per 30s.
        for _ in 0 ..< 90 where watchdog.observe(isExactZero: true, duration: 1) {
            rebuilds += 1
        }
        #expect(rebuilds == 3)
        #expect(watchdog.rebuildCount == 3)
        #expect(watchdog.exactZeroSeconds == 90)
    }

    @Test func fractionalBufferDurationsAccumulateTowardTheThreshold() {
        var watchdog = ZeroBufferWatchdog()
        var rebuilds = 0
        // 300 buffers of 0.1s each = 30s, matching real IOProc chunk sizes
        // far better than whole-second observations do.
        for _ in 0 ..< 300 where watchdog.observe(isExactZero: true, duration: 0.1) {
            rebuilds += 1
        }
        #expect(rebuilds == 1)
        #expect(abs(watchdog.exactZeroSeconds - 30) < 0.0001)
    }

    @Test func aQuietMeetingAndAMissingGrantAreIndistinguishableToTheWatchdog() {
        // research.md: an all-zero buffer is ambiguous between a missing
        // TCC grant and genuine silence. The watchdog treats both
        // identically — that's the point of never failing the capture here.
        var watchdog = ZeroBufferWatchdog()
        for _ in 0 ..< 30 {
            _ = watchdog.observe(isExactZero: true, duration: 1)
        }
        #expect(watchdog.rebuildCount == 1)
    }
}
