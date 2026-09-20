import AVFoundation
import Core
@testable import Diarize
import DiarizerInterface
import Foundation
import Testing

private func extract(_ segments: [RawSpeakerSegment], audioSeconds: Double, duration: Int, sampleRate: Double = 16000) throws -> (
    fixture: DiarizeFixture,
    count: Int,
) {
    let fixture = DiarizeFixture()
    try fixture.plantAudio(seconds: audioSeconds, sampleRate: sampleRate)
    let artifact = DiarizationArtifactBuilder.build(raw: segments, utteranceTimings: [])
    let count = try SnippetExtractor.extract(
        artifact: artifact,
        audio: fixture.audioURL(),
        directory: fixture.cacheDirectory().appendingPathComponent("snippets", isDirectory: true),
        durationSeconds: duration,
    )
    return (fixture, count)
}

@Test func aSnippetIsTheConfiguredLengthFromTheSpeakersLongestSegment() throws {
    let (fixture, count) = try extract([raw(1, 0, 3), raw(1, 10, 25), raw(2, 3, 10)], audioSeconds: 30, duration: 8)
    defer { fixture.cleanUp() }

    #expect(count == 2)
    let wav = try Data(contentsOf: fixture.snippetURL("speaker_1.wav"))
    #expect(wavSampleCount(wav) == 8 * 16000)
    #expect(String(bytes: wav.prefix(4), encoding: .ascii) == "RIFF")
    #expect(String(bytes: wav[8 ..< 12], encoding: .ascii) == "WAVE")
}

@Test func aSnippetOpensAsSixteenKilohertzMonoInt16Audio() throws {
    let (fixture, _) = try extract([raw(1, 0, 12)], audioSeconds: 12, duration: 8)
    defer { fixture.cleanUp() }

    let file = try AVAudioFile(forReading: fixture.snippetURL("speaker_1.wav"))
    #expect(file.fileFormat.sampleRate == 16000)
    #expect(file.fileFormat.channelCount == 1)
    #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
    #expect(file.length == 8 * 16000)
}

@Test func aSpeakerWithLessAudioThanTheClipGetsAShorterClip() throws {
    let (fixture, _) = try extract([raw(1, 0, 3.5), raw(2, 4, 20)], audioSeconds: 20, duration: 8)
    defer { fixture.cleanUp() }

    #expect(try wavSampleCount(Data(contentsOf: fixture.snippetURL("speaker_1.wav"))) == Int(3.5 * 16000))
}

@Test func aClipIsFilledFromTheSpeakersOtherSegmentsWhenTheLongestIsTooShort() throws {
    let (fixture, _) = try extract([raw(1, 0, 3), raw(1, 5, 7), raw(1, 9, 13), raw(2, 13, 20)], audioSeconds: 20, duration: 8)
    defer { fixture.cleanUp() }

    #expect(try wavSampleCount(Data(contentsOf: fixture.snippetURL("speaker_1.wav"))) == 8 * 16000)
}

@Test func theClipLengthIsClampedBeforeItIsUsed() async throws {
    for (configured, expected) in [(3, 5), (20, 10)] {
        let fixture = DiarizeFixture()
        defer { fixture.cleanUp() }
        try fixture.plantAudio(seconds: 30)

        _ = try await DiarizeStage.run(
            meetingID: fixture.meetingID,
            transcript: CanonicalTranscriptBuilder.build([]),
            utteranceTimings: [],
            audio: fixture.audioURL(),
            diarizer: StubDiarizer(.success([raw(1, 0, 30)])),
            config: DiarizerConfig(snippetDurationSeconds: configured),
        )

        #expect(try wavSampleCount(Data(contentsOf: fixture.snippetURL("speaker_1.wav"))) == expected * 16000)
    }
}

@Test func theEnvelopeIsTwoHundredLittleEndianFloat32PeaksInUnitRange() throws {
    let (fixture, _) = try extract([raw(1, 0, 10)], audioSeconds: 10, duration: 8)
    defer { fixture.cleanUp() }

    let data = try Data(contentsOf: fixture.snippetURL("speaker_1.envelope"))
    #expect(data.count == 200 * 4)
    let peaks = (0 ..< 200).map { index in
        Float(bitPattern: data.subdata(in: index * 4 ..< index * 4 + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
    }
    #expect(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
    #expect(peaks.contains { $0 > 0.05 })
    #expect(try #require(peaks.last) > #require(peaks.first), "the tone steps up in level, so the envelope must rise")
}

@Test func snippetFilesAreOwnerOnly() throws {
    let (fixture, _) = try extract([raw(1, 0, 6)], audioSeconds: 6, duration: 8)
    defer { fixture.cleanUp() }

    #expect(try permissions(of: fixture.snippetURL("speaker_1.wav")) == 0o600)
    #expect(try permissions(of: fixture.snippetURL("speaker_1.envelope")) == 0o600)
}

@Test func audioAtAnotherSampleRateIsConvertedToSixteenKilohertz() throws {
    let (fixture, _) = try extract([raw(1, 0, 10)], audioSeconds: 10, duration: 8, sampleRate: 44100)
    defer { fixture.cleanUp() }

    let samples = try wavSampleCount(Data(contentsOf: fixture.snippetURL("speaker_1.wav")))
    #expect(abs(samples - 8 * 16000) <= 64)
}

@Test func noSegmentsWriteNothing() throws {
    let (fixture, count) = try extract([], audioSeconds: 5, duration: 8)
    defer { fixture.cleanUp() }

    #expect(count == 0)
    #expect(try !FileManager.default.fileExists(atPath: fixture.cacheDirectory().appendingPathComponent("snippets").path))
}

@Test func aSegmentBeyondTheEndOfTheAudioLeavesThatSpeakerWithoutASnippet() throws {
    let (fixture, count) = try extract([raw(1, 0, 4), raw(2, 50, 60)], audioSeconds: 5, duration: 8)
    defer { fixture.cleanUp() }

    #expect(count == 1)
    #expect(try !FileManager.default.fileExists(atPath: fixture.snippetURL("speaker_2.wav").path))
}

/// Peak amplitude, in unit range, of `range` seconds of a snippet WAV.
private func peak(of wav: Data, seconds range: Range<Double>) -> Float {
    let samples = wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let slice = samples[Int(range.lowerBound * 16000) ..< Int(range.upperBound * 16000)]
    return Float(slice.map { abs(Int($0)) }.max() ?? 0) / 32767
}

@Test func theClipHoldsTheAudioOfTheLongestSegmentNotAnotherOne() throws {
    let (fixture, _) = try extract([raw(1, 0, 3), raw(1, 10, 25)], audioSeconds: 30, duration: 8)
    defer { fixture.cleanUp() }

    let wav = try Data(contentsOf: fixture.snippetURL("speaker_1.wav"))
    #expect(abs(peak(of: wav, seconds: 0 ..< 8) - 0.9) < 0.01, "seconds 10-18 of the tone peak at 0.9; seconds 0-3 would peak at 0.3")
}

@Test func aShortLongestSegmentIsFollowedByTheNextLongestFromItsOwnStart() throws {
    let (fixture, _) = try extract([raw(1, 0, 3), raw(1, 3, 10)], audioSeconds: 12, duration: 8)
    defer { fixture.cleanUp() }

    let wav = try Data(contentsOf: fixture.snippetURL("speaker_1.wav"))
    #expect(abs(peak(of: wav, seconds: 0 ..< 1) - 0.4) < 0.01, "the clip opens at second 3 of the tone")
    #expect(abs(peak(of: wav, seconds: 7 ..< 8) - 0.1) < 0.01, "and its last second is the first second of the other segment")
}

@Test func aRerunWithFewerSpeakersRemovesTheSnippetsItNoLongerWrites() throws {
    let (fixture, _) = try extract([raw(1, 0, 6), raw(2, 6, 12)], audioSeconds: 12, duration: 8)
    defer { fixture.cleanUp() }
    let directory = try fixture.cacheDirectory().appendingPathComponent("snippets", isDirectory: true)

    let count = try SnippetExtractor.extract(
        artifact: DiarizationArtifactBuilder.build(raw: [raw(1, 0, 6)], utteranceTimings: []),
        audio: fixture.audioURL(),
        directory: directory,
        durationSeconds: 8,
    )

    #expect(count == 1)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["speaker_1.wav", "speaker_1.envelope"])
}

@Test func aRerunWithNoSegmentsClearsEverySnippet() throws {
    let (fixture, _) = try extract([raw(1, 0, 6)], audioSeconds: 6, duration: 8)
    defer { fixture.cleanUp() }
    let directory = try fixture.cacheDirectory().appendingPathComponent("snippets", isDirectory: true)

    let count = try SnippetExtractor.extract(artifact: DiarizationArtifact(segments: []), audio: fixture.audioURL(), directory: directory, durationSeconds: 8)

    #expect(count == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@Test func theSnippetsDirectoryIsOwnerOnly() throws {
    let (fixture, _) = try extract([raw(1, 0, 6)], audioSeconds: 6, duration: 8)
    defer { fixture.cleanUp() }

    let directory = try fixture.cacheDirectory().appendingPathComponent("snippets", isDirectory: true)
    #expect(try permissions(of: directory) == 0o700)
}

@Test func nonFiniteSamplesAreWrittenAsSilenceInsteadOfTrapping() {
    let wav = SnippetExtractor.wavData([.nan, .infinity, -.infinity, 0.5])
    let envelope = SnippetExtractor.envelopeData([.nan, 0.5])

    #expect(wavSampleCount(wav) == 4)
    #expect(wav.dropFirst(44).prefix(6).allSatisfy { $0 == 0 })
    #expect(wav.dropFirst(50).contains { $0 != 0 })
    #expect(envelope.count == 200 * 4)
}
