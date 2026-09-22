import AVFoundation
@testable import Capture
import Foundation
import Testing

/// A sine tone as a mono, non-interleaved Float32 `AVAudioPCMBuffer` at
/// `sampleRate` — the shape both `AVAudioEngine`'s mic tap and
/// `ProcessTapSource`'s IOProc deliver.
private func sineBuffer(sampleRate: Double, seconds: Double, frequency: Double = 440, amplitude: Float = 0.3) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData)[0]
    for frame in 0 ..< Int(frames) {
        samples[frame] = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
    }
    return buffer
}

/// Decodes little-endian Int16 PCM (the shape `AudioMixer` hands
/// `WAVWriter.write(_:)`) back into samples for assertions.
private func int16Samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { raw in
        raw.bindMemory(to: Int16.self).map(Int16.init(littleEndian:))
    }
}

@Suite(.serialized)
struct AudioMixerTests {
    @Test func mismatchedMicAndSystemRatesAreResampledAndMixedToSixteenKilohertzMono() throws {
        let mixer = AudioMixer()
        let seconds = 1.0

        try mixer.ingestSystem(sineBuffer(sampleRate: 48000, seconds: seconds))
        try mixer.ingestMic(sineBuffer(sampleRate: 44100, seconds: seconds))

        let output = mixer.flush()
        let samples = int16Samples(output)

        // 16 kHz mono PCM16: two bytes per frame, one second of audio.
        #expect(output.count.isMultiple(of: 2))
        #expect(abs(samples.count - 16000) <= 32)

        // Two 0.3-amplitude tones summed should read louder than either tone
        // alone (0.3 * Int16.max ≈ 9830) but never clip past Int16's range.
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 12000)
        #expect(peak <= Int(Int16.max))
    }

    @Test func aMicDeniedSessionMixesSystemAudioAlone() throws {
        let mixer = AudioMixer()

        try mixer.ingestSystem(sineBuffer(sampleRate: 48000, seconds: 0.5))
        // ingestMic is never called — the mic-denied path (AC's mic-denied
        // scenario) is CaptureSession simply never calling it.
        let output = mixer.flush()
        let samples = int16Samples(output)

        #expect(abs(samples.count - 8000) <= 32)
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 5000)
    }

    @Test func drainWithheldsFramesUntilBothActiveSourcesCatchUpButFlushPadsTheRemainder() throws {
        let mixer = AudioMixer()

        // Establish both pipelines with one buffer each.
        try mixer.ingestSystem(sineBuffer(sampleRate: 16000, seconds: 0.1))
        try mixer.ingestMic(sineBuffer(sampleRate: 16000, seconds: 0.1))
        let firstDrain = mixer.drain()
        #expect(!firstDrain.isEmpty)

        // The system side gets more audio; the mic side (already
        // established) has nothing further queued.
        try mixer.ingestSystem(sineBuffer(sampleRate: 16000, seconds: 0.1))
        let heldBack = mixer.drain()
        #expect(heldBack.isEmpty)

        // flush() pads the starved mic side with silence instead of
        // waiting forever.
        let tail = mixer.flush()
        #expect(!tail.isEmpty)
        #expect(int16Samples(tail).count >= 1500)
    }

    @Test func emptyMixerDrainsAndFlushesToNothing() {
        let mixer = AudioMixer()
        #expect(mixer.drain().isEmpty)
        #expect(mixer.flush().isEmpty)
    }

    @Test func aSystemFormatChangeMidCaptureCarriesOverAlreadyConvertedSamplesInsteadOfDroppingThem() throws {
        let mixer = AudioMixer()

        // Nothing drains between these two ingests (mic is never used, so
        // there's no pairing to hold the first epoch back) — the second
        // call arrives at a different sample rate, the shape a
        // `ProcessTapSource` watchdog rebuild produces mid-capture.
        try mixer.ingestSystem(sineBuffer(sampleRate: 48000, seconds: 0.2))
        try mixer.ingestSystem(sineBuffer(sampleRate: 44100, seconds: 0.2))

        let samples = int16Samples(mixer.flush())

        // Both 0.2s epochs must survive the format change: ~0.4s at 16kHz.
        #expect(abs(samples.count - 6400) <= 64)
    }

    @Test func drainPadsAStarvedSideOnceTheGapPassesTheBoundInsteadOfWaitingForever() throws {
        let mixer = AudioMixer()

        // Establish both pipelines so the mic side counts as "active" —
        // otherwise it would never be waited on in the first place.
        try mixer.ingestSystem(sineBuffer(sampleRate: 16000, seconds: 0.01))
        try mixer.ingestMic(sineBuffer(sampleRate: 16000, seconds: 0.01))
        _ = mixer.drain()

        // The system side races more than 2 seconds ahead of the mic side,
        // which delivers nothing further — past `drain()`'s starvation
        // bound, so it must stop waiting and pad the mic side with silence
        // instead of returning empty forever.
        try mixer.ingestSystem(sineBuffer(sampleRate: 16000, seconds: 2.1))

        #expect(!mixer.drain().isEmpty)
    }
}
