import Core
import Foundation
import Orchestrator
import State
@testable import Summarize
import SummarizerInterface
import Testing

private struct LeakyStoreError: Error, CustomStringConvertible {
    var description: String {
        "leaked: /Users/someone/vault/secret note.md"
    }
}

// MARK: - The error-to-exit mapping

@Test func aCompletedOutcomeExitsZero() async {
    let exit = await SummarizeWorker.exitStatus { .completed(targetState: .summarizing) }

    #expect(exit == WorkerExitStatus(code: WorkerExitCode.success))
}

@Test func aFailedOutcomeExitsWithTheStateError() async {
    let exit = await SummarizeWorker.exitStatus { .failed(targetState: .summarizationFailed, errorClass: "summarizer_rate_limited") }

    #expect(exit == WorkerExitStatus(code: WorkerExitCode.stateError))
}

@Test func anUnknownMeetingExitsThreeWithAFixedSentence() async {
    let exit = await SummarizeWorker.exitStatus { throw StateStoreError.meetingNotFound(id: "01ABC") }

    #expect(exit == WorkerExitStatus(code: WorkerExitCode.meetingNotFound, message: "no meeting has the given ID."))
}

@Test func anyOtherErrorExitsTwoNamingTheTypeAndNeverItsText() async {
    let exit = await SummarizeWorker.exitStatus { throw LeakyStoreError() }

    #expect(exit.code == WorkerExitCode.stateError)
    let message = exit.message ?? ""
    #expect(message.contains("LeakyStoreError"))
    #expect(!message.contains("/Users/someone"))
    #expect(!message.contains("secret note"))
}

// MARK: - Through the real stage

@Test func anUnknownMeetingThroughTheRealStageExitsThreeAndRecordsNothing() async throws {
    let fixture = try await StageFixture(insertMeetingRow: false)
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let exit = await SummarizeWorker.run(
        meetingID: fixture.meetingID,
        stateStore: fixture.store,
        orchestrator: SummarizerOrchestrator(primary: primary, fallback: StageStubStrategy(.failure(SummarizerError.malformedResponse))),
        glossary: Glossary(),
        config: SummarizerConfig(),
        calendarSource: nil,
    )

    #expect(exit.code == WorkerExitCode.meetingNotFound)
    #expect(await primary.callCount == 0)
}

@Test func aSummarizerFailureThroughTheRealStageExitsWithTheStateError() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let exit = await SummarizeWorker.run(
        meetingID: fixture.meetingID,
        stateStore: fixture.store,
        orchestrator: SummarizerOrchestrator(
            primary: StageStubStrategy(.failure(SummarizerError.networkTimeout)),
            fallback: StageStubStrategy(.failure(SummarizerError.networkTimeout)),
        ),
        glossary: Glossary(),
        config: SummarizerConfig(),
        calendarSource: nil,
    )

    #expect(exit == WorkerExitStatus(code: WorkerExitCode.stateError))
    #expect(try await fixture.store.fetchMeeting(id: fixture.meetingID.rawValue)?.state == "summarization_failed")
}

@Test func aSuccessfulRunThroughTheRealStageExitsZero() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let exit = await SummarizeWorker.run(
        meetingID: fixture.meetingID,
        stateStore: fixture.store,
        orchestrator: SummarizerOrchestrator(
            primary: StageStubStrategy(.success(makeStageGrounded())),
            fallback: StageStubStrategy(.failure(SummarizerError.malformedResponse)),
        ),
        glossary: Glossary(),
        config: SummarizerConfig(),
        calendarSource: nil,
    )

    #expect(exit == WorkerExitStatus(code: WorkerExitCode.success))
}
