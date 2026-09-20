import AVFoundation
import Core
import DiarizerInterface
import Foundation
import Testing

/// Returns fixed raw segments or throws a fixed error, and counts its calls.
actor StubDiarizer: DiarizerStrategy {
    private let result: Result<[RawSpeakerSegment], any Error>
    private(set) var callCount = 0
    private(set) var lastTimings: [UtteranceTiming] = []

    init(_ result: Result<[RawSpeakerSegment], any Error>) {
        self.result = result
    }

    func diarize(
        transcript _: CanonicalTranscript,
        utteranceTimings: [UtteranceTiming],
        audio _: URL,
        config _: DiarizerConfig,
    ) async throws -> DiarizationArtifact {
        callCount += 1
        lastTimings = utteranceTimings
        return try DiarizationArtifactBuilder.build(raw: result.get(), utteranceTimings: utteranceTimings)
    }
}

/// An error whose message could leak a path or transcript text if the stage
/// ever recorded it.
struct LeakyDiarizerError: Error, CustomStringConvertible {
    let secret: String
    var description: String {
        "leaked: \(secret)"
    }
}

/// A WAV of `seconds` holding a 220 Hz tone, whose amplitude steps up every
/// second so different stretches of it have different peaks. Written through
/// AVFoundation, at `sampleRate`, the way a real capture would be opened.
func writeToneWAV(to url: URL, seconds: Double, sampleRate: Double = 16000) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    let channel = try #require(buffer.int16ChannelData?[0])
    for frame in 0 ..< Int(frames) {
        let second = Double(frame) / sampleRate
        let amplitude = min(0.1 * (1 + second.rounded(.down)), 0.9)
        channel[frame] = Int16(amplitude * sin(2 * .pi * 220 * second) * 32767)
    }
    try file.write(from: buffer)
}

/// A real cache directory for a fresh meeting id; `cleanUp()` removes only it.
struct DiarizeFixture {
    let meetingID = MeetingID.generate()

    func cleanUp() {
        guard let directory = try? CacheArtifactWriter.cacheDirectory(for: meetingID) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    func cacheDirectory() throws -> URL {
        try CacheArtifactWriter.cacheDirectory(for: meetingID)
    }

    func audioURL() throws -> URL {
        try cacheDirectory().appendingPathComponent("audio.wav")
    }

    func artifactURL() throws -> URL {
        try cacheDirectory().appendingPathComponent("diarization.json")
    }

    func snippetURL(_ name: String) throws -> URL {
        try cacheDirectory().appendingPathComponent("snippets", isDirectory: true).appendingPathComponent(name)
    }

    func plantAudio(seconds: Double, sampleRate: Double = 16000) throws {
        try FileManager.default.createDirectory(at: cacheDirectory(), withIntermediateDirectories: true)
        try writeToneWAV(to: audioURL(), seconds: seconds, sampleRate: sampleRate)
    }
}

func permissions(of url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}

func raw(_ speaker: Int, _ start: Double, _ end: Double) -> RawSpeakerSegment {
    RawSpeakerSegment(speaker: speaker, startSeconds: start, endSeconds: end)
}

/// Sample count of a canonical 44-byte-header 16-bit mono WAV.
func wavSampleCount(_ data: Data) -> Int {
    (data.count - 44) / 2
}
