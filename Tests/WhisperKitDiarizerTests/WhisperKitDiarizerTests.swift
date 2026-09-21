import AVFoundation
import Core
import DiarizerInterface
import Foundation
@testable import SpeakerKit
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

/// SpeakerKit's Pyannote backend turns a per-speaker activity matrix into one
/// `.speakerId` segment run per speaker, so two speakers talking at once come
/// out as two overlapping segments. `.multiple` and `.noMatch` are produced
/// only when words are matched to speakers, which this diarizer never does.
@Test func overlappingSpeechSurvivesAsPerSpeakerSegmentsAndCountsInTheOverlapRatio() {
    // Frame rate 10: speaker 0 is active over [0 s, 4 s), speaker 1 over [2 s, 6 s).
    let matrix = [
        Array(repeating: 1, count: 40) + Array(repeating: 0, count: 20),
        Array(repeating: 0, count: 20) + Array(repeating: 1, count: 40),
    ]
    let result = DiarizationResult(binaryMatrix: matrix, diarizationFrameRate: 10)

    #expect(result.segments.allSatisfy { $0.speaker.speakerId != nil })
    let raw = WhisperKitDiarizer.rawSegments(from: result.segments)
    #expect(raw.count == 2)

    let artifact = DiarizationArtifactBuilder.build(raw: raw, utteranceTimings: [])
    let ratios = artifact.segments.map(\.voiceProfile.overlapRatio)
    #expect(ratios == [0.5, 0.5])
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
    let bundles = [
        "speaker_segmenter/v/SpeakerSegmenter.mlmodelc",
        "speaker_embedder/v/SpeakerEmbedder.mlmodelc",
        "speaker_embedder/v/SpeakerEmbedderPreprocessor.mlmodelc",
        "speaker_clusterer/v/PldaProjector.mlmodelc",
    ]
    for bundle in bundles {
        let directory = folder.appendingPathComponent(bundle, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicWriter.write(Data("not a model".utf8), to: directory.appendingPathComponent("coremldata.bin"))
        try AtomicWriter.write(Data("{}".utf8), to: directory.appendingPathComponent("metadata.json"))
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

// MARK: - Model loading, with a stub in place of SpeakerKit

private struct StubEngine: WhisperKitDiarizer.Engine {
    let segments: [SpeakerSegment]

    func diarize(samples _: [Float]) async throws -> [SpeakerSegment] {
        segments
    }
}

private let twoSpeakers = [
    SpeakerSegment(speaker: .speakerId(0), startTime: 0, endTime: 3, frameRate: 10),
    SpeakerSegment(speaker: .speakerId(1), startTime: 3, endTime: 6, frameRate: 10),
]

/// Counts loads, and can hold every load until `release()` so a test can start
/// several diarizations while the first is still loading.
private actor LoaderProbe {
    private(set) var loadCount = 0
    private var failuresLeft: Int
    private var gate: CheckedContinuation<Void, Never>?
    private var isHeld: Bool

    init(hold: Bool = false, failures: Int = 0) {
        isHeld = hold
        failuresLeft = failures
    }

    func load() async throws -> any WhisperKitDiarizer.Engine {
        loadCount += 1
        if isHeld {
            await withCheckedContinuation { gate = $0 }
        }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw DiarizerError.modelLoadFailed
        }
        return StubEngine(segments: twoSpeakers)
    }

    func release() {
        isHeld = false
        gate?.resume()
        gate = nil
    }
}

private func diarize(_ diarizer: WhisperKitDiarizer, audio: URL, modelFolder: URL) async throws -> DiarizationArtifact {
    try await diarizer.diarize(
        transcript: CanonicalTranscriptBuilder.build([]),
        utteranceTimings: [],
        audio: audio,
        config: DiarizerConfig(modelFolder: modelFolder),
    )
}

private func makeDiarizer(probe: LoaderProbe) -> WhisperKitDiarizer {
    WhisperKitDiarizer(store: SpeakerKitModelStore(), loader: { _ in try await probe.load() })
}

@Test func aSuccessfulLoadDiarizesAndIsCountedOnce() async throws {
    let models = try makeRoot()
    let fixture = DiarizeFixtureForDiarizer()
    defer {
        try? FileManager.default.removeItem(at: models)
        fixture.cleanUp()
    }
    try plantModels(in: models)
    try fixture.plantAudio()
    let probe = LoaderProbe()
    let diarizer = makeDiarizer(probe: probe)

    let artifact = try await diarize(diarizer, audio: fixture.audio, modelFolder: models)

    #expect(artifact.segments.count == 2)
    #expect(await diarizer.modelLoadCount == 1)
    #expect(await probe.loadCount == 1)
}

@Test func aLoadedModelIsReusedForALaterCall() async throws {
    let models = try makeRoot()
    let fixture = DiarizeFixtureForDiarizer()
    defer {
        try? FileManager.default.removeItem(at: models)
        fixture.cleanUp()
    }
    try plantModels(in: models)
    try fixture.plantAudio()
    let probe = LoaderProbe()
    let diarizer = makeDiarizer(probe: probe)

    let first = try await diarize(diarizer, audio: fixture.audio, modelFolder: models)
    let second = try await diarize(diarizer, audio: fixture.audio, modelFolder: models)

    #expect(first == second)
    #expect(await probe.loadCount == 1)
    #expect(await diarizer.modelLoadCount == 1)
}

@Test func aDifferentModelFolderLoadsAgain() async throws {
    let first = try makeRoot()
    let second = try makeRoot()
    let fixture = DiarizeFixtureForDiarizer()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
        fixture.cleanUp()
    }
    try plantModels(in: first)
    try plantModels(in: second)
    try fixture.plantAudio()
    let probe = LoaderProbe()
    let diarizer = makeDiarizer(probe: probe)

    _ = try await diarize(diarizer, audio: fixture.audio, modelFolder: first)
    _ = try await diarize(diarizer, audio: fixture.audio, modelFolder: second)

    #expect(await probe.loadCount == 2)
    #expect(await diarizer.modelLoadCount == 2)
}

@Test func callsThatArriveDuringALoadShareIt() async throws {
    let models = try makeRoot()
    let fixture = DiarizeFixtureForDiarizer()
    defer {
        try? FileManager.default.removeItem(at: models)
        fixture.cleanUp()
    }
    try plantModels(in: models)
    try fixture.plantAudio()
    let probe = LoaderProbe(hold: true)
    let diarizer = makeDiarizer(probe: probe)
    let audio = fixture.audio

    async let one = diarize(diarizer, audio: audio, modelFolder: models)
    async let two = diarize(diarizer, audio: audio, modelFolder: models)
    while await probe.loadCount == 0 {
        await Task.yield()
    }
    // Both calls are past audio loading and waiting on the one load, or about
    // to be: a second load would show up as a second count once released.
    try await Task.sleep(for: .milliseconds(200))
    await probe.release()
    let artifacts = try await [one, two]

    #expect(artifacts[0] == artifacts[1])
    #expect(await probe.loadCount == 1)
    #expect(await diarizer.modelLoadCount == 1)
}

@Test func aFailedLoadIsNotCountedAndTheNextCallLoadsAgain() async throws {
    let models = try makeRoot()
    let fixture = DiarizeFixtureForDiarizer()
    defer {
        try? FileManager.default.removeItem(at: models)
        fixture.cleanUp()
    }
    try plantModels(in: models)
    try fixture.plantAudio()
    let probe = LoaderProbe(failures: 1)
    let diarizer = makeDiarizer(probe: probe)

    await #expect(throws: DiarizerError.modelLoadFailed) {
        try await diarize(diarizer, audio: fixture.audio, modelFolder: models)
    }
    #expect(await diarizer.modelLoadCount == 0)

    _ = try await diarize(diarizer, audio: fixture.audio, modelFolder: models)

    #expect(await probe.loadCount == 2)
    #expect(await diarizer.modelLoadCount == 1)
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
