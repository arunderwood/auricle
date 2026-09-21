import Core
import Diarize
import DiarizerInterface
import Foundation
import Orchestrator
import Telemetry
import Testing
@testable import Transcribe
import TranscriberInterface

/// Transcribes to a fixed transcript and reports fixed utterance timings.
private actor TimedStubTranscriber: TranscriberStrategy {
    let transcript: CanonicalTranscript
    let timings: [UtteranceTiming]

    init(transcript: CanonicalTranscript, timings: [UtteranceTiming]) {
        self.transcript = transcript
        self.timings = timings
    }

    func transcribe(audio _: URL, config _: TranscriberConfig) async throws -> CanonicalTranscript {
        transcript
    }

    func transcribeTimed(audio _: URL, config _: TranscriberConfig) async throws -> TimedTranscript {
        TimedTranscript(transcript: transcript, utteranceTimings: timings)
    }
}

private actor StubDiarizer: DiarizerStrategy {
    let result: Result<[RawSpeakerSegment], any Error>

    init(_ result: Result<[RawSpeakerSegment], any Error>) {
        self.result = result
    }

    func diarize(
        transcript _: CanonicalTranscript,
        utteranceTimings: [UtteranceTiming],
        audio _: URL,
        config _: DiarizerConfig,
    ) async throws -> DiarizationArtifact {
        try DiarizationArtifactBuilder.build(raw: result.get(), utteranceTimings: utteranceTimings)
    }
}

/// The step the CLI builds: a closure over the real `DiarizeStage` and a
/// stubbed diarizer.
private func step(_ diarizer: StubDiarizer) -> TranscribeStage.DiarizationStep {
    { input in
        try await DiarizeStage.run(
            meetingID: input.meetingID,
            transcript: input.transcript,
            utteranceTimings: input.utteranceTimings,
            audio: input.audio,
            diarizer: diarizer,
            config: DiarizerConfig(),
        )
    }
}

private let twoUtteranceTimings = [
    UtteranceTiming(index: 0, startSeconds: 0, endSeconds: 3),
    UtteranceTiming(index: 1, startSeconds: 3, endSeconds: 6),
]

private func run(
    _ fixture: TranscribeStageFixture,
    diarizer: StubDiarizer,
) async throws -> StageRunner.StageOutcome {
    try await TranscribeStage.run(
        meetingID: fixture.meetingID,
        stateStore: fixture.store,
        stageRunner: fixture.runner,
        transcriber: TimedStubTranscriber(transcript: stubTranscript(), timings: twoUtteranceTimings),
        diarize: step(diarizer),
    )
}

@Test func aDiarizationStepMergesItsMetaIntoTheOneCompletedRow() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 8)

    let outcome = try await run(fixture, diarizer: StubDiarizer(.success([raw(1, 0, 3), raw(2, 3, 6)])))

    #expect(TranscribeStage.exitCode(for: outcome) == 0)
    let events = try await fixture.events()
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(events.allSatisfy { $0.stage == "transcribe" })
    let metadata = try metadataObject(#require(events.last))
    #expect(Set(metadata.keys) == ["model_id", "audio_duration_s", "transcript_chars", "diarize"])
    #expect(metadata["model_id"] as? String == "whisper-large-v3-turbo")
    let diarize = try #require(metadata["diarize"] as? [String: Any])
    #expect(diarize["model_id"] as? String == "speakerkit-pyannote")
    #expect(diarize["segment_count"] as? Int == 2)
    #expect(diarize["speaker_count"] as? Int == 2)
    #expect(diarize["snippet_count"] as? Int == 2)
    #expect(try await fixture.state() == "transcribing")
}

@Test func theTranscriptTimingsReachTheDiarizerAndTheTranscriptStaysSingleSpeaker() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 8)

    _ = try await run(fixture, diarizer: StubDiarizer(.success([raw(1, 0, 3), raw(2, 3, 6)])))

    let artifact = try JSONDecoder().decode(
        DiarizationArtifact.self,
        from: Data(contentsOf: fixture.cacheDirectory().appendingPathComponent("diarization.json")),
    )
    #expect(artifact.segments.map(\.utteranceIndex) == [
        DiarizationArtifact.UtteranceRange(first: 0, last: 0),
        DiarizationArtifact.UtteranceRange(first: 1, last: 1),
    ])
    #expect(try fixture.readTranscript() == stubTranscript())
    #expect(try fixture.readTranscript().utterances.allSatisfy { $0.speakerLabel == "Speaker_1" })
}

@Test func withoutAStepTheRowHasNoDiarizeKey() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()

    _ = try await fixture.run(transcriber: StubTranscriber(.success(stubTranscript())))

    let metadata = try metadataObject(#require(try await fixture.events().last))
    #expect(metadata["diarize"] == nil)
    #expect(Set(metadata.keys) == ["model_id", "audio_duration_s", "transcript_chars"])
}

@Test(arguments: [
    (DiarizerError.modelUnavailable, "diarize_model_unavailable", Int32(75)),
    (DiarizerError.modelLoadFailed, "diarize_model_load_failed", Int32(75)),
    (DiarizerError.diarizationFailed, "diarize_failed", Int32(75)),
    (DiarizerError.audioUnreadable, "diarize_audio_unreadable", Int32(2)),
])
func aDiarizerFailureFailsTheTranscribeRowWithItsClassAndExitCode(error: DiarizerError, errorClass: String, exitCode: Int32) async throws {
    let expectedMessage: String? = String(describing: error)
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()

    let outcome = try await run(fixture, diarizer: StubDiarizer(.failure(error)))

    guard case let .failed(targetState, _, message, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .transcriptionFailed)
    #expect(message == expectedMessage)
    #expect(TranscribeStage.exitCode(for: outcome) == exitCode)
    #expect(try await fixture.events().map(\.event) == ["started", "failed"])
    #expect(try metadataObject(#require(await fixture.events().last))["error_class"] as? String == errorClass)
    #expect(try await fixture.state() == "transcription_failed")
}

@Test func anUnknownDiarizerErrorIsPermanentAndRecordsItsTypeNameOnly() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()

    let outcome = try await run(fixture, diarizer: StubDiarizer(.failure(LeakyTranscriberError(secret: "/Users/someone/private.wav"))))

    guard case let .failed(_, errorClass, message, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(errorClass == "diarize_unexpected_error")
    #expect(message == String(reflecting: LeakyTranscriberError.self))
    #expect(message?.contains("private") == false)
    #expect(TranscribeStage.exitCode(for: outcome) == 2)
}

@Test func aFailureToWriteTheDiarizationArtifactIsPermanent() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    try FileManager.default.createDirectory(
        at: fixture.cacheDirectory().appendingPathComponent("diarization.json"),
        withIntermediateDirectories: true,
    )

    let outcome = try await run(fixture, diarizer: StubDiarizer(.success([raw(1, 0, 3)])))

    guard case let .failed(_, errorClass, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(errorClass == "diarization_write_failed")
    #expect(TranscribeStage.exitCode(for: outcome) == 2)
}

@Test func aFailureToWriteASnippetIsPermanent() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    try FileManager.default.createDirectory(
        at: fixture.cacheDirectory().appendingPathComponent("snippets/speaker_1.wav"),
        withIntermediateDirectories: true,
    )

    let outcome = try await run(fixture, diarizer: StubDiarizer(.success([raw(1, 0, 3)])))

    guard case let .failed(_, errorClass, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(errorClass == "snippet_write_failed")
    #expect(TranscribeStage.exitCode(for: outcome) == 2)
}

@Test func theWorkerRunsTheStepAndExitsZero() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 8)

    let exit = await TranscribeWorker.run(
        meetingID: fixture.meetingID,
        stateStore: fixture.store,
        stageRunner: fixture.runner,
        transcriber: TimedStubTranscriber(transcript: stubTranscript(), timings: twoUtteranceTimings),
        config: TranscriberConfig(),
        diarize: step(StubDiarizer(.success([raw(1, 0, 6)]))),
        ensureModel: {},
    )

    #expect(exit == TranscribeWorker.Exit(code: 0, message: nil))
    let metadata = try metadataObject(#require(try await fixture.events().last))
    #expect((metadata["diarize"] as? [String: Any])?["snippet_count"] as? Int == 1)
}

private func raw(_ speaker: Int, _ start: Double, _ end: Double) -> RawSpeakerSegment {
    RawSpeakerSegment(speaker: speaker, startSeconds: start, endSeconds: end)
}

// MARK: - Resume

/// Fails its first `failures` calls, then succeeds, and counts its calls.
private actor FlakyDiarizer: DiarizerStrategy {
    private var failures: Int
    private(set) var receivedTimings: [[UtteranceTiming]] = []

    init(failures: Int) {
        self.failures = failures
    }

    func diarize(
        transcript _: CanonicalTranscript,
        utteranceTimings: [UtteranceTiming],
        audio _: URL,
        config _: DiarizerConfig,
    ) async throws -> DiarizationArtifact {
        receivedTimings.append(utteranceTimings)
        if failures > 0 {
            failures -= 1
            throw DiarizerError.diarizationFailed
        }
        return DiarizationArtifactBuilder.build(raw: [raw(1, 0, 3), raw(2, 3, 6)], utteranceTimings: utteranceTimings)
    }
}

private func runCounting(
    _ fixture: TranscribeStageFixture,
    transcriber: StubTimedCounter,
    diarizer: FlakyDiarizer,
) async throws -> StageRunner.StageOutcome {
    try await TranscribeStage.run(
        meetingID: fixture.meetingID,
        stateStore: fixture.store,
        stageRunner: fixture.runner,
        transcriber: transcriber,
        diarize: { input in
            try await DiarizeStage.run(
                meetingID: input.meetingID,
                transcript: input.transcript,
                utteranceTimings: input.utteranceTimings,
                audio: input.audio,
                diarizer: diarizer,
                config: DiarizerConfig(),
            )
        },
    )
}

private actor StubTimedCounter: TranscriberStrategy {
    private(set) var callCount = 0

    func transcribe(audio _: URL, config _: TranscriberConfig) async throws -> CanonicalTranscript {
        stubTranscript()
    }

    func transcribeTimed(audio _: URL, config _: TranscriberConfig) async throws -> TimedTranscript {
        callCount += 1
        return TimedTranscript(transcript: stubTranscript(), utteranceTimings: twoUtteranceTimings)
    }
}

@Test func aRetryAfterADiarizationFailureResumesFromTheWrittenTranscript() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 8)
    let transcriber = StubTimedCounter()
    let diarizer = FlakyDiarizer(failures: 1)

    let first = try await runCounting(fixture, transcriber: transcriber, diarizer: diarizer)
    guard case .failed = first else {
        Issue.record("expected .failed outcome, got \(first)")
        return
    }
    let second = try await runCounting(fixture, transcriber: transcriber, diarizer: diarizer)

    #expect(TranscribeStage.exitCode(for: second) == 0)
    #expect(await transcriber.callCount == 1)
    #expect(await diarizer.receivedTimings == [twoUtteranceTimings, twoUtteranceTimings])
    #expect(try fixture.readTranscript() == stubTranscript())
}

@Test func aTranscriptWithoutUsableTimingsIsTranscribedAgain() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 8)
    let transcriber = StubTimedCounter()
    let diarizer = FlakyDiarizer(failures: 1)

    _ = try await runCounting(fixture, transcriber: transcriber, diarizer: diarizer)
    try AtomicWriter.write(Data("{}".utf8), to: fixture.cacheDirectory().appendingPathComponent("utterance_timings.json"))
    let second = try await runCounting(fixture, transcriber: transcriber, diarizer: diarizer)

    #expect(TranscribeStage.exitCode(for: second) == 0)
    #expect(await transcriber.callCount == 2)
}
