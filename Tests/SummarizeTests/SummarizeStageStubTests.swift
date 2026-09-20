import Core
import Foundation
import Orchestrator
@testable import Summarize
import SummarizerInterface
import Testing

private let failingSummarizer = SummarizerError.rateLimited

@Test func aFailedSummarizerCallUnderPublishAnywayWritesTheStubAndCompletesIntoPersisting() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    try fixture.plantAttribution(["Speaker_1": "[[Ben]]"])

    let outcome = try await fixture.run(
        primary: StageStubStrategy(.failure(failingSummarizer)),
        fallback: StageStubStrategy(.failure(failingSummarizer)),
        publishAnyway: true,
    )

    guard case let .completed(targetState, metadataJSON) = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .persisting)
    #expect(SummarizeStage.exitCode(for: outcome) == 0)
    #expect(try await fixture.state() == "persisting")

    let stub = try fixture.readSummary()
    #expect(stub.needsSummary)
    #expect(stub.summary.isEmpty)
    #expect(stub.actionItems.isEmpty)
    #expect(stub.decisions.isEmpty)
    #expect(stub.title == stageExpectedTitle)
    #expect(stub.calendarEventTitle == nil)
    #expect(stub.attendees.isEmpty)
    #expect(stub.selfWikilink == nil)
    #expect(stub.needsCalendarEnrichment)
    #expect(stub.needsAttribution)
    #expect(stub.transcriptSegments == [
        TranscriptSegmentArtifact(speaker: "[[Ben]]", text: stageFirstText),
        TranscriptSegmentArtifact(speaker: "[[Speaker_2]]", text: stageSecondText),
    ])

    let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.summaryURL())) as? [String: Any])
    #expect(raw["schema_version"] as? Int == 1)
    #expect(raw["needs_summary"] as? Bool == true)

    let events = try await fixture.events()
    #expect(events.map(\.event) == ["started", "completed"])
    let metadata = try stageMetadataObject(#require(events.last))
    #expect(metadata["error_class"] as? String == "summarizer_rate_limited")
    #expect(metadataJSON != nil)
}

@Test func anArtifactThatCannotBeMappedUnderPublishAnywayAlsoWritesTheStub() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let outsideTheTranscript = GroundedItem(
        text: "Bad",
        grounding: GroundingPointer(transcriptStart: 0, transcriptEnd: 100_000, sourceMethod: .citations),
    )

    let outcome = try await fixture.run(
        primary: StageStubStrategy(.success(makeStageGrounded(actionItems: [outsideTheTranscript]))),
        publishAnyway: true,
    )

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(try fixture.readSummary().needsSummary)
    let completed = try #require(try await fixture.events().last)
    #expect(try stageMetadataObject(completed)["error_class"] as? String == "quote_extraction_failed")
}

@Test func aFailedSummarizerCallWithoutPublishAnywayWritesNoStub() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let outcome = try await fixture.run(
        primary: StageStubStrategy(.failure(failingSummarizer)),
        fallback: StageStubStrategy(.failure(failingSummarizer)),
    )

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "summarizer_rate_limited")
}

@Test func aFailureBeforeTheCalendarStepWritesNoStubEvenUnderPublishAnyway() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }

    let missingTranscript = try await fixture.run(
        primary: StageStubStrategy(.success(makeStageGrounded())),
        publishAnyway: true,
    )
    try await expectStageFailure(missingTranscript, fixture: fixture, errorClass: "transcript_missing")
}

@Test func anUnavailablePromptSetWritesNoStubEvenUnderPublishAnyway() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let outcome = try await fixture.run(
        primary: StageStubStrategy(.success(makeStageGrounded())),
        publishAnyway: true,
        promptSetHash: { _ in throw StageLeakyError(secret: "x") },
    )

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "prompt_set_unavailable")
}

@Test func aCancelledRunUnderPublishAnywayWritesNoStub() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let outcome = try await fixture.run(
        primary: StageStubStrategy(.failure(CancellationError())),
        fallback: StageStubStrategy(.failure(CancellationError())),
        publishAnyway: true,
    )

    guard case let .failed(targetState, _, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .summarizationFailed)
    #expect(try await fixture.state() == "summarization_failed")
    let summaryPath = try fixture.summaryURL().path
    #expect(!FileManager.default.fileExists(atPath: summaryPath))
}

@Test func aFailureUnderPublishAnywayNeverOverwritesACompleteSummary() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let good = SummaryArtifact(
        title: "Kept", calendarEventTitle: nil, attendees: [], selfWikilink: nil,
        needsAttribution: false, needsCalendarEnrichment: true,
        summary: "A good summary.", actionItems: [], decisions: [], transcriptSegments: [],
    )
    try CacheArtifactWriter.write(good, for: fixture.meetingID, named: "summary.json", schemaVersion: 1)

    let outcome = try await fixture.run(
        primary: StageStubStrategy(.failure(failingSummarizer)),
        fallback: StageStubStrategy(.failure(failingSummarizer)),
        publishAnyway: true,
    )

    guard case let .failed(targetState, errorClass, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .summarizationFailed)
    #expect(errorClass == "summarizer_rate_limited")
    #expect(try fixture.readSummary().summary == "A good summary.")
}
