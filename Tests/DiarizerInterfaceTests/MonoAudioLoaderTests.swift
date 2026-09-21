import AVFoundation
import DiarizerInterface
import Foundation
import Testing

private func writeTone(to url: URL, sampleRate: Double, frames: Int) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples = try #require(buffer.int16ChannelData?[0])
    for index in 0 ..< frames {
        samples[index] = Int16(8000 * sin(2 * Double.pi * 440 * Double(index) / sampleRate))
    }
    try file.write(from: buffer)
}

/// One chunk is 65536 input frames, so the longer lengths cross chunk
/// boundaries, and the odd lengths leave a fractional output sample at the end.
@Test(arguments: [(44100.0, 44100), (44100.0, 100_003), (44100.0, 300_001), (48000.0, 200_000), (8000.0, 70001)])
func resamplingKeepsEveryOutputSampleUpToTheEndOfTheFile(sampleRate: Double, frames: Int) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mono-loader-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeTone(to: url, sampleRate: sampleRate, frames: frames)

    let samples = try MonoAudioLoader.load(url: url)

    let expected = Double(frames) * MonoAudioLoader.sampleRate / sampleRate
    // Rounding of the last fractional sample. An unflushed resampler tail is
    // about 6 samples short at 44.1 kHz and hundreds short at 8 kHz.
    #expect(abs(Double(samples.count) - expected) <= 1.5, "expected about \(expected) samples, got \(samples.count)")
}

@Test func theTailOfTheFileIsNotSilentAfterResampling() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mono-loader-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeTone(to: url, sampleRate: 44100, frames: 100_003)

    let samples = try MonoAudioLoader.load(url: url)

    let tail = samples.suffix(64)
    #expect(tail.contains { abs($0) > 0.01 })
}
