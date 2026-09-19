import Core
import Foundation
import GRDB
import Orchestrator
import State
import Testing
@testable import Transcribe
import TranscriberInterface

/// Stands in for making the model present. It counts its calls and records
/// what the state store held at the moment it ran, so a test can prove it ran
/// after the meeting lookup and before the stage's first transaction.
private actor EnsureModelProbe {
    private(set) var callCount = 0
    private(set) var eventsSeen: [String] = []
    private(set) var stateSeen: String?

    func run(store: StateStore, meetingID: MeetingID, pause: Duration?) async {
        callCount += 1
        // A worker that started the stage without waiting would record `started`
        // during this pause.
        if let pause {
            try? await Task.sleep(for: pause)
        }
        let events = await (try? store.fetchStageEvents(meetingID: meetingID.rawValue)) ?? []
        eventsSeen = events.map(\.event)
        stateSeen = try? await store.fetchMeeting(id: meetingID.rawValue)?.state
    }
}

private func runWorker(
    _ fixture: TranscribeStageFixture,
    transcriber: StubTranscriber,
    probe: EnsureModelProbe = EnsureModelProbe(),
    pause: Duration? = nil,
    beforeStage: (@Sendable () async -> Void)? = nil,
) async -> TranscribeWorker.Exit {
    let store = fixture.store
    let meetingID = fixture.meetingID
    return await TranscribeWorker.run(
        meetingID: meetingID,
        stateStore: store,
        stageRunner: fixture.runner,
        transcriber: transcriber,
        config: TranscriberConfig(),
        ensureModel: {
            await probe.run(store: store, meetingID: meetingID, pause: pause)
            await beforeStage?()
        },
    )
}

// MARK: - Unknown meeting

@Test func anUnknownMeetingExitsThreeWithoutEnsuringTheModelOrRecordingAnything() async throws {
    let fixture = try await TranscribeStageFixture(insertMeetingRow: false)
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let stub = StubTranscriber(.success(stubTranscript()))
    let probe = EnsureModelProbe()

    let exit = await runWorker(fixture, transcriber: stub, probe: probe)

    #expect(exit.code == 3)
    #expect(exit.message != nil)
    #expect(await probe.callCount == 0)
    #expect(await stub.callCount == 0)
    #expect(try await fixture.events().isEmpty)
    #expect(try !FileManager.default.fileExists(atPath: fixture.transcriptURL().path))
}

@Test func aMeetingThatVanishesWhileTheModelIsEnsuredExitsThree() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let stub = StubTranscriber(.success(stubTranscript()))
    let queue = fixture.queue

    let exit = await runWorker(fixture, transcriber: stub) {
        try? await queue.write { try $0.execute(sql: "DELETE FROM meetings") }
    }

    #expect(exit.code == 3)
    #expect(await stub.callCount == 0)
    #expect(try await fixture.events().isEmpty)
}

// MARK: - Ordering

@Test func ensureModelIsAwaitedAfterTheLookupAndBeforeTheStagesFirstTransaction() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let probe = EnsureModelProbe()

    let exit = await runWorker(fixture, transcriber: StubTranscriber(.success(stubTranscript())), probe: probe, pause: .milliseconds(50))

    #expect(exit.code == 0)
    #expect(await probe.callCount == 1)
    #expect(await probe.eventsSeen.isEmpty)
    #expect(await probe.stateSeen == "captured")
    #expect(try await fixture.events().map(\.event) == ["started", "completed"])
}

// MARK: - Exit codes

@Test func aSuccessfulStageExitsZeroWithNoMessage() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    let stub = StubTranscriber(.success(stubTranscript()))

    let exit = await runWorker(fixture, transcriber: stub)

    #expect(exit == TranscribeWorker.Exit(code: 0, message: nil))
    #expect(await stub.callCount == 1)
    #expect(try await fixture.state() == "transcribing")
    #expect(try fixture.readTranscript() == stubTranscript())
}

@Test(arguments: [TranscriberError.modelUnavailable, .modelLoadFailed, .transcriptionFailed])
func aRetryableFailureExits75(error: TranscriberError) async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()

    let exit = await runWorker(fixture, transcriber: StubTranscriber(.failure(error)))

    #expect(exit == TranscribeWorker.Exit(code: 75, message: nil))
    #expect(try await fixture.state() == "transcription_failed")
}

@Test func aMissingAudioFileExitsTwoAsAPermanentFailure() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    let stub = StubTranscriber(.success(stubTranscript()))

    let exit = await runWorker(fixture, transcriber: stub)

    #expect(exit == TranscribeWorker.Exit(code: 2, message: nil))
    #expect(await stub.callCount == 0)
    #expect(try await fixture.state() == "transcription_failed")
}

@Test func anUnknownTranscriberErrorExitsTwoAsAPermanentFailure() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()

    let exit = await runWorker(fixture, transcriber: StubTranscriber(.failure(LeakyTranscriberError(secret: "private words"))))

    #expect(exit == TranscribeWorker.Exit(code: 2, message: nil))
}

// MARK: - State store failures

@Test func aStateStoreThatCannotBeReadExitsTwoWithoutEnsuringTheModel() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    try await fixture.queue.write { try $0.execute(sql: "DROP TABLE meetings") }
    let stub = StubTranscriber(.success(stubTranscript()))
    let probe = EnsureModelProbe()

    let exit = await runWorker(fixture, transcriber: stub, probe: probe)

    #expect(exit.code == 2)
    #expect(exit.message == "could not read the meeting (\(String(reflecting: DatabaseError.self))).")
    #expect(await probe.callCount == 0)
    #expect(await stub.callCount == 0)
}

@Test func aStateStoreThatCannotRecordTheStageExitsTwoAndNamesOnlyTheErrorType() async throws {
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAudio()
    try await fixture.queue.write { try $0.execute(sql: "DROP TABLE stage_events") }
    let stub = StubTranscriber(.success(stubTranscript()))

    let exit = await runWorker(fixture, transcriber: stub)

    #expect(exit.code == 2)
    #expect(exit.message == "could not record its progress (\(String(reflecting: DatabaseError.self))).")
    #expect(await stub.callCount == 0)
    #expect(try !FileManager.default.fileExists(atPath: fixture.transcriptURL().path))
}
