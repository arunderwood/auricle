import Core
import Diarize
import DiarizerInterface
import Foundation
import Telemetry
import Testing

private let transcript = CanonicalTranscriptBuilder.build([(speakerLabel: "Speaker_1", text: "hello"), (speakerLabel: "Speaker_1", text: "world")])

private func run(
    _ fixture: DiarizeFixture,
    diarizer: StubDiarizer,
    timings: [UtteranceTiming] = [],
    config: DiarizerConfig = DiarizerConfig(),
) async throws -> DiarizeMeta {
    try await DiarizeStage.run(
        meetingID: fixture.meetingID,
        transcript: transcript,
        utteranceTimings: timings,
        audio: fixture.audioURL(),
        diarizer: diarizer,
        config: config,
    )
}

private func expectFailure(
    _ fixture: DiarizeFixture,
    diarizer: StubDiarizer,
    errorClass: String,
    message: String? = nil,
) async throws {
    do {
        _ = try await run(fixture, diarizer: diarizer)
        Issue.record("expected the stage to throw \(errorClass)")
    } catch let error as ClassifiedStageError {
        #expect(error.errorClass == errorClass)
        if let message {
            #expect(error.errorMessage == message)
        }
    }
}

@Test func twoSpeakersProduceTheArtifactSnippetsAndMeta() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 30)
    let timings = [
        UtteranceTiming(index: 0, startSeconds: 0, endSeconds: 10),
        UtteranceTiming(index: 1, startSeconds: 10, endSeconds: 25),
    ]

    let meta = try await run(fixture, diarizer: StubDiarizer(.success([raw(4, 0, 12), raw(9, 12, 28)])), timings: timings)

    #expect(meta == DiarizeMeta(modelID: "speakerkit-pyannote", segmentCount: 2, speakerCount: 2, snippetCount: 2))
    let data = try Data(contentsOf: fixture.artifactURL())
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["schema_version"] as? Int == 1)
    let artifact = try JSONDecoder().decode(DiarizationArtifact.self, from: data)
    #expect(artifact.segments.map(\.speakerLabel) == ["Speaker_1", "Speaker_2"])
    #expect(artifact.segments.first?.utteranceIndex == DiarizationArtifact.UtteranceRange(first: 0, last: 1))
    #expect(try permissions(of: fixture.artifactURL()) == 0o600)
    for name in ["speaker_1.wav", "speaker_1.envelope", "speaker_2.wav", "speaker_2.envelope"] {
        #expect(try FileManager.default.fileExists(atPath: fixture.snippetURL(name).path), "\(name)")
    }
}

@Test func theStepIsHandedTheTimingsAndRecordsNothingElse() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 10)
    let stub = StubDiarizer(.success([raw(1, 0, 5)]))
    let timings = [UtteranceTiming(index: 0, startSeconds: 0, endSeconds: 5)]

    _ = try await run(fixture, diarizer: stub, timings: timings)

    #expect(await stub.callCount == 1)
    #expect(await stub.lastTimings == timings)
}

@Test func withoutTimingsSegmentsCarryNoUtteranceIndexAndTheStepCompletes() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 10)

    _ = try await run(fixture, diarizer: StubDiarizer(.success([raw(1, 0, 5)])))

    let artifact = try JSONDecoder().decode(DiarizationArtifact.self, from: Data(contentsOf: fixture.artifactURL()))
    #expect(artifact.segments.allSatisfy { $0.utteranceIndex == nil })
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.artifactURL())) as? [String: Any])
    let segment = try #require((json["segments"] as? [[String: Any]])?.first)
    #expect(segment["utterance_index"] == nil)
}

@Test func zeroSegmentsWriteAnEmptyArtifactAndNoSnippets() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 5)

    let meta = try await run(fixture, diarizer: StubDiarizer(.success([])))

    #expect(meta == DiarizeMeta(modelID: "speakerkit-pyannote", segmentCount: 0, speakerCount: 0, snippetCount: 0))
    let artifact = try JSONDecoder().decode(DiarizationArtifact.self, from: Data(contentsOf: fixture.artifactURL()))
    #expect(artifact.segments.isEmpty)
    #expect(try !FileManager.default.fileExists(atPath: fixture.cacheDirectory().appendingPathComponent("snippets").path))
}

@Test func theMetaCarriesTheConfiguredModelID() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 5)

    let meta = try await run(fixture, diarizer: StubDiarizer(.success([])), config: DiarizerConfig(modelID: "other"))

    #expect(meta.modelID == "other")
}

@Test func twoRunsOverTheSameAudioWriteByteIdenticalFiles() async throws {
    let first = DiarizeFixture()
    let second = DiarizeFixture()
    defer {
        first.cleanUp()
        second.cleanUp()
    }
    try first.plantAudio(seconds: 20)
    try second.plantAudio(seconds: 20)
    let segments = [raw(1, 0, 9), raw(2, 8, 20)]

    _ = try await run(first, diarizer: StubDiarizer(.success(segments)))
    _ = try await run(second, diarizer: StubDiarizer(.success(segments)))

    #expect(try Data(contentsOf: first.artifactURL()) == Data(contentsOf: second.artifactURL()))
    for name in ["speaker_1.wav", "speaker_1.envelope", "speaker_2.wav", "speaker_2.envelope"] {
        #expect(try Data(contentsOf: first.snippetURL(name)) == Data(contentsOf: second.snippetURL(name)), "\(name)")
    }
}

@Test func runningTheSameMeetingTwiceRewritesIdenticalFiles() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 10)
    let stub = StubDiarizer(.success([raw(1, 0, 9)]))

    _ = try await run(fixture, diarizer: stub)
    let before = try Data(contentsOf: fixture.snippetURL("speaker_1.wav"))
    _ = try await run(fixture, diarizer: stub)

    #expect(try Data(contentsOf: fixture.snippetURL("speaker_1.wav")) == before)
}

@Test(arguments: [
    (DiarizerError.modelUnavailable, "diarize_model_unavailable"),
    (DiarizerError.modelLoadFailed, "diarize_model_load_failed"),
    (DiarizerError.diarizationFailed, "diarize_failed"),
    (DiarizerError.audioUnreadable, "diarize_audio_unreadable"),
])
func aDiarizerErrorFoldsToItsStableClass(error: DiarizerError, errorClass: String) async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 5)

    try await expectFailure(fixture, diarizer: StubDiarizer(.failure(error)), errorClass: errorClass)
    #expect(try !FileManager.default.fileExists(atPath: fixture.artifactURL().path))
}

@Test func anUnknownErrorRecordsItsTypeNameOnly() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 5)

    try await expectFailure(
        fixture,
        diarizer: StubDiarizer(.failure(LeakyDiarizerError(secret: "/Users/someone/audio.wav"))),
        errorClass: "diarize_unexpected_error",
        message: String(reflecting: LeakyDiarizerError.self),
    )
}

@Test func onlyTheModelAndDecodeClassesAreRetryable() {
    #expect(DiarizeErrorClass.retryable == ["diarize_model_unavailable", "diarize_model_load_failed", "diarize_failed"])
    for error in DiarizeStageError.allCases {
        #expect(DiarizeErrorClass.retryable.contains(error.errorClass) == [.modelUnavailable, .modelLoadFailed, .diarizationFailed].contains(error))
    }
}

@Test func aFailureToWriteTheArtifactIsAPermanentWriteFailure() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 5)
    try FileManager.default.createDirectory(at: fixture.artifactURL(), withIntermediateDirectories: true)

    try await expectFailure(fixture, diarizer: StubDiarizer(.success([raw(1, 0, 3)])), errorClass: "diarization_write_failed", message: "artifactWriteFailed")
    #expect(!DiarizeErrorClass.retryable.contains("diarization_write_failed"))
}

@Test func aFailureToWriteASnippetIsAPermanentSnippetFailure() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 5)
    try FileManager.default.createDirectory(at: fixture.snippetURL("speaker_1.wav"), withIntermediateDirectories: true)

    try await expectFailure(fixture, diarizer: StubDiarizer(.success([raw(1, 0, 3)])), errorClass: "snippet_write_failed", message: "snippetWriteFailed")
    #expect(!DiarizeErrorClass.retryable.contains("snippet_write_failed"))
}

@Test func rewritingTheArtifactRemovesWhatWasWrittenAgainstTheOldOne() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 30)
    let directory = try fixture.cacheDirectory()
    let bystander = directory.appendingPathComponent("transcript.json")
    for name in ["attribution.json", "diarization_suggestions.json", "transcript.json"] {
        try AtomicWriter.write(Data("{}".utf8), to: directory.appendingPathComponent(name))
    }

    _ = try await run(fixture, diarizer: StubDiarizer(.success([raw(4, 0, 12), raw(9, 12, 28)])))

    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("attribution.json").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("diarization_suggestions.json").path))
    #expect(FileManager.default.fileExists(atPath: bystander.path))
    #expect(try FileManager.default.fileExists(atPath: fixture.artifactURL().path))
}

@Test func aFailedDiarizationLeavesTheOldArtifactAndItsDependents() async throws {
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 30)
    let attribution = try fixture.cacheDirectory().appendingPathComponent("attribution.json")
    try AtomicWriter.write(Data("{}".utf8), to: attribution)

    try await expectFailure(fixture, diarizer: StubDiarizer(.failure(DiarizerError.diarizationFailed)), errorClass: "diarize_failed")

    #expect(FileManager.default.fileExists(atPath: attribution.path))
}
