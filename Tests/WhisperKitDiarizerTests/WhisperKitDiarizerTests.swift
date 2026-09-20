import AVFoundation
import Core
import DiarizerInterface
import Foundation
import SpeakerKit
import Testing
@testable import WhisperKitDiarizer

@Test func kitConfigCannotReachTheNetwork() {
    let root = URL(fileURLWithPath: "/models/root", isDirectory: true)
    let folder = root.appendingPathComponent("models/argmaxinc/speakerkit-coreml", isDirectory: true)

    let config = WhisperKitDiarizer.kitConfig(for: SpeakerKitModelStore.ResolvedModel(modelFolder: folder, root: root))

    #expect(config.download == false)
    #expect(config.load == true)
    #expect(config.modelDownloadConfig.modelFolder == folder.path)
    #expect(config.modelDownloadConfig.downloadBase == root.path)
}

@Test func overlappingSpeechIsKeptSoTheOverlapRatioCanBeMeasured() {
    #expect(WhisperKitDiarizer.diarizationOptions.useExclusiveReconciliation == false)
}

@Test func segmentsWithNoSingleSpeakerAreLeftOut() {
    let segments = [
        SpeakerSegment(speaker: .speakerId(2), startTime: 1.5, endTime: 4, frameRate: 10),
        SpeakerSegment(speaker: .noMatch, startTime: 4, endTime: 5, frameRate: 10),
        SpeakerSegment(speaker: .multiple([1, 2]), startTime: 5, endTime: 6, frameRate: 10),
    ]

    #expect(WhisperKitDiarizer.rawSegments(from: segments) == [RawSpeakerSegment(speaker: 2, startSeconds: 1.5, endSeconds: 4)])
}

@Test func aMissingModelFailsAsModelUnavailableWithoutTouchingTheNetwork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("speakerkit-missing-\(UUID().uuidString)", isDirectory: true)
    let fixture = DiarizeFixtureForDiarizer()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let diarizer = WhisperKitDiarizer(store: SpeakerKitModelStore(root: root))

    await #expect(throws: DiarizerError.modelUnavailable) {
        try await diarizer.diarize(
            transcript: CanonicalTranscriptBuilder.build([]),
            utteranceTimings: [],
            audio: fixture.audio,
            config: DiarizerConfig(),
        )
    }
    #expect(await diarizer.modelLoadCount == 0)
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func unreadableAudioFailsAsAudioUnreadable() async throws {
    let fixture = DiarizeFixtureForDiarizer()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    try AtomicWriter.write(Data("not audio".utf8), to: fixture.audio)

    await #expect(throws: DiarizerError.audioUnreadable) {
        try await WhisperKitDiarizer().diarize(
            transcript: CanonicalTranscriptBuilder.build([]),
            utteranceTimings: [],
            audio: fixture.audio,
            config: DiarizerConfig(),
        )
    }
}

@Test func aModelFolderThatCannotBeLoadedFailsAsLoadFailedAndIsNotCounted() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("speakerkit-broken-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["speaker_segmenter", "speaker_embedder", "speaker_clusterer"] {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("\(name)/stub", isDirectory: true), withIntermediateDirectories: true)
    }
    let fixture = DiarizeFixtureForDiarizer()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let diarizer = WhisperKitDiarizer()

    await #expect(throws: DiarizerError.modelLoadFailed) {
        try await diarizer.diarize(
            transcript: CanonicalTranscriptBuilder.build([]),
            utteranceTimings: [],
            audio: fixture.audio,
            config: DiarizerConfig(modelFolder: folder),
        )
    }
    #expect(await diarizer.modelLoadCount == 0)
}

// MARK: - Live

/// Runs only where `AURICLE_SPEAKERKIT_MODEL_FOLDER` names a provisioned
/// SpeakerKit repository folder and `AURICLE_REFERENCE_WAV` a short speech
/// recording. It proves the models load once for two calls and that two runs
/// write identical artifacts. Skipped, and so reported as unverified, elsewhere.
private enum Live {
    static let modelFolder = ProcessInfo.processInfo.environment["AURICLE_SPEAKERKIT_MODEL_FOLDER"]
    static let audio = ProcessInfo.processInfo.environment["AURICLE_REFERENCE_WAV"]
    static var isAvailable: Bool {
        modelFolder != nil && audio != nil
    }
}

@Test(.enabled(if: Live.isAvailable, "needs AURICLE_SPEAKERKIT_MODEL_FOLDER and AURICLE_REFERENCE_WAV"))
func aLoadedModelIsReusedAndARerunIsIdentical() async throws {
    let modelFolder = try URL(fileURLWithPath: #require(Live.modelFolder), isDirectory: true)
    let audio = try URL(fileURLWithPath: #require(Live.audio))
    let config = DiarizerConfig(modelFolder: modelFolder)
    let diarizer = WhisperKitDiarizer()
    let transcript = CanonicalTranscriptBuilder.build([])

    let first = try await diarizer.diarize(transcript: transcript, utteranceTimings: [], audio: audio, config: config)
    let second = try await diarizer.diarize(transcript: transcript, utteranceTimings: [], audio: audio, config: config)

    #expect(await diarizer.modelLoadCount == 1)
    #expect(!first.segments.isEmpty)
    #expect(first == second)
}

// MARK: - Fixture

private struct DiarizeFixtureForDiarizer {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diarizer-audio-\(UUID().uuidString)", isDirectory: true)
    var audio: URL {
        directory.appendingPathComponent("audio.wav")
    }

    func plantAudio() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: audio, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000))
        buffer.frameLength = 16000
        try file.write(from: buffer)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
