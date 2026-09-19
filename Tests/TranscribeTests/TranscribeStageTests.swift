@testable import Core
import Foundation
import Orchestrator
import State
import Telemetry
import Testing
@testable import Transcribe
import TranscriberInterface

// MARK: - Happy path

@Test func stageWritesTheTranscriptAndCompletesIntoTranscribing() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 2)
    let transcript = stubTranscript()
    let stub = StubTranscriber(.success(transcript))

    let outcome = try await fixture.run(transcriber: stub)

    guard case let .completed(targetState, metadataJSON) = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .transcribing)
    #expect(metadataJSON != nil)
    #expect(TranscribeStage.exitCode(for: outcome) == 0)
    #expect(try await fixture.state() == "transcribing")
    #expect(try fixture.readTranscript() == transcript)
    #expect(await stub.callCount == 1)
    #expect(try await stub.lastAudio == (fixture.audioURL()))
}

@Test func stageRecordsStartedThenCompletedWithTheTranscribeMeta() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 2)
    let transcript = stubTranscript()

    _ = try await fixture.run(transcriber: StubTranscriber(.success(transcript)))

    let events = try await fixture.events()
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(events.allSatisfy { $0.stage == "transcribe" })
    let metadata = try metadataObject(#require(events.last))
    #expect(metadata["model_id"] as? String == "whisper-large-v3-turbo")
    #expect(metadata["audio_duration_s"] as? Int == 2)
    #expect(metadata["transcript_chars"] as? Int == transcript.text.count)
    #expect(Set(metadata.keys) == ["model_id", "audio_duration_s", "transcript_chars"])
}

@Test func stageRecordsTheWholeSecondDurationOfTheAudio() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio(seconds: 3.4)

    _ = try await fixture.run(transcriber: StubTranscriber(.success(stubTranscript())))

    let completed = try #require(try await fixture.events().last)
    #expect(try metadataObject(completed)["audio_duration_s"] as? Int == 3)
}

@Test func stagePassesTheConfiguredModelToTheTranscriberAndTheMeta() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let stub = StubTranscriber(.success(stubTranscript()))
    let config = TranscriberConfig(modelID: "another-model", modelFolder: URL(fileURLWithPath: "/models/another"))

    _ = try await fixture.run(transcriber: stub, config: config)

    #expect(await stub.lastConfig == config)
    let completed = try #require(try await fixture.events().last)
    #expect(try metadataObject(completed)["model_id"] as? String == "another-model")
}

@Test func transcriptFileCarriesSchemaVersionOneAndIsOwnerOnly() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()

    _ = try await fixture.run(transcriber: StubTranscriber(.success(stubTranscript())))

    let data = try Data(contentsOf: fixture.transcriptURL())
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["schema_version"] as? Int == 1)
    let permissions = try FileManager.default.attributesOfItem(atPath: fixture.transcriptURL().path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func identicalTranscriptsProduceByteIdenticalFiles() async throws {
    let first = try await TranscribeStageFixture()
    let second = try await TranscribeStageFixture()
    defer {
        first.cleanUp()
        second.cleanUp()
    }
    try first.plantAudio()
    try second.plantAudio()

    _ = try await first.run(transcriber: StubTranscriber(.success(stubTranscript(["café ☕", "naïve 🚀 plan"]))))
    _ = try await second.run(transcriber: StubTranscriber(.success(stubTranscript(["café ☕", "naïve 🚀 plan"]))))

    #expect(try Data(contentsOf: first.transcriptURL()) == Data(contentsOf: second.transcriptURL()))
}

@Test func writtenTranscriptHoldsCanonicalPrefixedNFCText() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let transcript = stubTranscript(["cafe\u{301} open\r\nlate", "  padded  ", "   ", "\n"])

    _ = try await fixture.run(transcriber: StubTranscriber(.success(transcript)))

    let written = try fixture.readTranscript()
    #expect(Array(written.text.unicodeScalars) == Array("Speaker_1: caf\u{E9} open\nlate\nSpeaker_1: padded".unicodeScalars))
    #expect(Array(written.text.unicodeScalars) == Array(written.text.precomposedStringWithCanonicalMapping.unicodeScalars))
    #expect(written.utterances.count == 2)
    let bytes = Array(written.text.utf8)
    for utterance in written.utterances {
        let text = try #require(String(bytes: bytes[utterance.start ..< utterance.end], encoding: .utf8))
        #expect(text.hasPrefix("Speaker_1: "))
    }
}

// MARK: - Zero segments

@Test func stageCompletesWithAnEmptyTranscriptWhenTheTranscriberReturnsNoText() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()

    let outcome = try await fixture.run(transcriber: StubTranscriber(.success(stubTranscript([]))))

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    let written = try fixture.readTranscript()
    #expect(written.text.isEmpty)
    #expect(written.utterances.isEmpty)
    #expect(try await fixture.state() == "transcribing")
    let completed = try #require(try await fixture.events().last)
    #expect(try metadataObject(completed)["transcript_chars"] as? Int == 0)
}

// MARK: - Audio

@Test func missingAudioFailsPermanentlyWithoutCallingTheTranscriber() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    let stub = StubTranscriber(.success(stubTranscript()))

    let outcome = try await fixture.run(transcriber: stub)

    try await expectTranscribeFailure(outcome, fixture: fixture, errorClass: "audio_missing", exitCode: 2)
    #expect(await stub.callCount == 0)
}

@Test func unreadableAudioFailsPermanentlyWithoutCallingTheTranscriber() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantUnreadableAudio()
    let stub = StubTranscriber(.success(stubTranscript()))

    let outcome = try await fixture.run(transcriber: stub)

    try await expectTranscribeFailure(outcome, fixture: fixture, errorClass: "audio_unreadable", exitCode: 2)
    #expect(await stub.callCount == 0)
}

@Test func aTranscriberThatReportsUnreadableAudioIsAlsoPermanent() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()

    let outcome = try await fixture.run(transcriber: StubTranscriber(.failure(TranscriberError.audioUnreadable)))

    try await expectTranscribeFailure(outcome, fixture: fixture, errorClass: "audio_unreadable", exitCode: 2)
}

// MARK: - Transcriber failures

@Test(arguments: [
    (TranscriberError.modelUnavailable, "transcribe_model_unavailable"),
    (TranscriberError.modelLoadFailed, "transcribe_model_load_failed"),
    (TranscriberError.transcriptionFailed, "transcribe_failed"),
])
func retryableTranscriberFailuresExitWithTheRetryableCode(error: TranscriberError, errorClass: String) async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()

    let outcome = try await fixture.run(transcriber: StubTranscriber(.failure(error)))

    try await expectTranscribeFailure(outcome, fixture: fixture, errorClass: errorClass, exitCode: 75)
    guard case let .failed(_, _, errorMessage, _) = outcome else { return }
    #expect(errorMessage == String(describing: error))
}

@Test func anUnknownErrorIsPermanentAndRecordsOnlyItsTypeName() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let secret = "the quarterly numbers are terrible"

    let outcome = try await fixture.run(transcriber: StubTranscriber(.failure(LeakyTranscriberError(secret: secret))))

    try await expectTranscribeFailure(outcome, fixture: fixture, errorClass: "transcribe_unexpected_error", exitCode: 2)
    guard case let .failed(_, _, errorMessage, metadataJSON) = outcome else { return }
    #expect(errorMessage == String(reflecting: LeakyTranscriberError.self))
    #expect(errorMessage?.contains(secret) == false)
    #expect(metadataJSON?.contains(secret) != true)
    let failed = try #require(try await fixture.events().last)
    #expect(failed.metadataJSON?.contains(secret) != true)
    #expect(failed.errorMessage?.contains(secret) != true)
}

// MARK: - Transcript write

/// A directory at the artifact's own path is the deterministic trigger: the
/// atomic rename of a file onto a directory fails.
@Test func aTranscriptThatCannotBeWrittenFailsPermanently() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    try FileManager.default.createDirectory(at: fixture.transcriptURL(), withIntermediateDirectories: true)

    let outcome = try await fixture.run(transcriber: StubTranscriber(.success(stubTranscript())))

    guard case let .failed(targetState, errorClass, errorMessage, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .transcriptionFailed)
    #expect(errorClass == "transcript_write_failed")
    #expect(errorMessage == "transcriptWriteFailed")
    #expect(TranscribeStage.exitCode(for: outcome) == 2)
    #expect(try await fixture.state() == "transcription_failed")
    #expect(try await fixture.events().map(\.event) == ["started", "failed"])
}

// MARK: - Unknown meeting

@Test func anUnknownMeetingThrowsBeforeRecordingAnything() async throws {
    let fixture = try await TranscribeStageFixture(insertMeetingRow: false)
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let stub = StubTranscriber(.success(stubTranscript()))

    await #expect(throws: StateStoreError.meetingNotFound(id: fixture.meetingID.rawValue)) {
        _ = try await fixture.run(transcriber: stub)
    }

    #expect(try await fixture.events().isEmpty)
    #expect(await stub.callCount == 0)
    #expect(try !FileManager.default.fileExists(atPath: fixture.transcriptURL().path))
}

// MARK: - Exit codes

@Test func exitCodeIsZeroForACompletedOutcome() {
    #expect(TranscribeStage.exitCode(for: .completed(targetState: .transcribing)) == 0)
}

@Test func exitCodeIsTheRetryableCodeOnlyForTheRetryableClasses() {
    func code(_ errorClass: String) -> Int32 {
        TranscribeStage.exitCode(for: .failed(targetState: .transcriptionFailed, errorClass: errorClass))
    }
    #expect(WorkerExitCode.retryable == 75)
    for retryable in ["transcribe_model_unavailable", "transcribe_model_load_failed", "transcribe_failed"] {
        #expect(code(retryable) == 75)
    }
    for permanent in ["audio_missing", "audio_unreadable", "transcript_write_failed", "transcribe_unexpected_error", "anything_else"] {
        #expect(code(permanent) == 2)
    }
}

@Test func everyStageErrorClassIsDistinctAndSnakeCase() {
    let classes = TranscribeStageError.allCases.map(\.errorClass)
    #expect(Set(classes).count == classes.count)
    for errorClass in classes {
        #expect(errorClass.allSatisfy { $0.isLowercase || $0 == "_" })
    }
}
