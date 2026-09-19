import Core
import Foundation
import Orchestrator
import State
import Summarize
import SummarizerInterface
import Testing

// MARK: - Happy path

@Test func happyPathWithoutAttributionWritesTheUnenrichedSummaryAndRecordsTelemetry() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let outcome = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded(dropCount: 1))))

    guard case let .completed(targetState, metadataJSON) = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .persisting)
    #expect(SummarizeStage.exitCode(for: outcome) == 0)

    let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.summaryURL())) as? [String: Any])
    #expect(raw["schema_version"] as? Int == 1)

    let artifact = try fixture.readSummary()
    #expect(artifact.title == stageExpectedTitle)
    #expect(artifact.calendarEventTitle == nil)
    #expect(artifact.needsCalendarEnrichment)
    #expect(artifact.needsAttribution)
    #expect(artifact.attendees.isEmpty)
    #expect(artifact.selfWikilink == nil)
    #expect(artifact.summary == "A short summary.")
    #expect(artifact.actionItems == [QuotedItemArtifact(text: "Follow up with Ben", quote: stageActionQuote)])
    #expect(artifact.decisions == [QuotedItemArtifact(text: "Ship on Friday", quote: stageDecisionQuote)])
    #expect(artifact.transcriptSegments == [
        TranscriptSegmentArtifact(speaker: "[[Speaker_1]]", text: stageFirstText),
        TranscriptSegmentArtifact(speaker: "[[Speaker_2]]", text: stageSecondText),
    ])

    let telemetry = try #require(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue))
    #expect(telemetry.summarizationPath == "claude_api")
    #expect(telemetry.summarizationModel == "claude-opus-5")
    #expect(telemetry.summarizationEffortBudget == "medium")
    #expect(telemetry.costUSD == 0.32)
    #expect(telemetry.quoteValidationDropCount == 1)

    let events = try await fixture.events()
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(try await fixture.state() == "persisting")
    let completed = try #require(events.last)
    #expect(completed.metadataJSON == metadataJSON)
    let metadata = try stageMetadataObject(completed)
    #expect(metadata["model_id"] as? String == "claude-opus-5")
    #expect(metadata["effort_budget"] as? String == "medium")
    #expect(metadata["input_tokens"] as? Int == 4200)
    #expect(metadata["output_tokens"] as? Int == 900)
    #expect(metadata["thinking_tokens"] as? Int == 1200)
    #expect(metadata["cost_usd"] as? Double == 0.32)
    #expect(metadata["quote_validation_drop_count"] as? Int == 1)
    #expect(metadata["grounding_method"] as? String == "citations")
    #expect(metadata["fallback_triggered"] as? Bool == false)
    #expect(metadata["fallback_error_class"] == nil)
}

/// The two wedge-validation columns are written from values the stage resolves
/// itself, so a stage that dropped them or read the wrong mode's hash would
/// otherwise leave the row silently incomplete.
@Test func theTelemetryRowCarriesTheGroundingMethodAndTheAnsweringModesPromptSetHash() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let substringHash = String(repeating: "5a", count: 32)
    let citationsHash = String(repeating: "c1", count: 32)

    _ = try await fixture.run(
        primary: StageStubStrategy(.success(makeStageGrounded(method: .substring))),
        promptSetHash: { $0 == .substring ? substringHash : citationsHash },
    )

    let telemetry = try #require(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue))
    #expect(telemetry.groundingMethod == "substring")
    #expect(telemetry.summarizationPromptSetHash == substringHash)
}

@Test func telemetryRecordsTheConfiguredModelAndEffort() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    _ = try await fixture.run(
        primary: StageStubStrategy(.success(makeStageGrounded())),
        config: SummarizerConfig(modelIdentifier: "claude-test-model", effortLevel: .high),
    )

    let telemetry = try #require(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue))
    #expect(telemetry.summarizationModel == "claude-test-model")
    #expect(telemetry.summarizationEffortBudget == "high")
}

// MARK: - Attribution

@Test func attributionMappingEverySpeakerClearsNeedsAttributionAndNamesTheSegments() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    try fixture.plantAttribution(["Speaker_1": "[[Ada]]", "Speaker_2": "[[Ben]]"])

    let outcome = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded())))

    #expect(SummarizeStage.exitCode(for: outcome) == 0)
    let artifact = try fixture.readSummary()
    #expect(!artifact.needsAttribution)
    #expect(artifact.transcriptSegments.map(\.speaker) == ["[[Ada]]", "[[Ben]]"])
    #expect(artifact.attendees.isEmpty)
}

@Test func partialAttributionKeepsNeedsAttributionAndFallsBackToPlaceholderLinks() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    try fixture.plantAttribution(["Speaker_1": "[[Ada]]"])

    _ = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded())))

    let artifact = try fixture.readSummary()
    #expect(artifact.needsAttribution)
    #expect(artifact.transcriptSegments.map(\.speaker) == ["[[Ada]]", "[[Speaker_2]]"])
}

@Test func anEmptyAttributionValueLeavesTheSpeakerUnmappedAndNeedsAttributionTrue() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    try fixture.plantAttribution(["Speaker_1": "", "Speaker_2": "[[Ben]]"])

    _ = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded())))

    let artifact = try fixture.readSummary()
    #expect(artifact.needsAttribution)
    #expect(artifact.transcriptSegments.map(\.speaker) == ["[[Speaker_1]]", "[[Ben]]"])
}

@Test func malformedAttributionFailsWithoutCallingTheSummarizer() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    try CacheArtifactWriter.write(["speakers": ["not", "a", "map"]], for: fixture.meetingID, named: "attribution.json", schemaVersion: 1)
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary)

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "attribution_undecodable")
    #expect(await primary.callCount == 0)
}

// MARK: - Inputs

@Test func missingTranscriptFailsWithoutCallingTheSummarizer() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary)

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "transcript_missing")
    #expect(await primary.callCount == 0)
}

@Test func undecodableTranscriptFails() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try CacheArtifactWriter.write(["text": 5], for: fixture.meetingID, named: "transcript.json", schemaVersion: 1)

    let outcome = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded())))

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "transcript_undecodable")
}

@Test func missingCaptureStartedAtFailsWithoutCallingTheSummarizer() async throws {
    let fixture = try await StageFixture(captureStartedAt: nil)
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary)

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "capture_started_at_missing")
    #expect(await primary.callCount == 0)
}

@Test func unparseableCaptureStartedAtFailsTheSameWay() async throws {
    let fixture = try await StageFixture(captureStartedAt: "last tuesday")
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let outcome = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded())))

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "capture_started_at_missing")
}

@Test func utteranceRangeOutsideTheTranscriptFailsWithoutCallingTheSummarizer() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript(CanonicalTranscript(text: "short", utterances: [.init(speakerLabel: "Speaker_1", start: 0, end: 99)]))
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary)

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "segment_extraction_failed")
    #expect(await primary.callCount == 0)
}

@Test func missingMeetingRowThrowsMeetingNotFoundAndWritesNothing() async throws {
    let fixture = try await StageFixture(insertMeetingRow: false)
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    await #expect(throws: StateStoreError.meetingNotFound(id: fixture.meetingID.rawValue)) {
        try await fixture.run(primary: primary)
    }

    let summaryURL = try fixture.summaryURL()
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))
    #expect(try await fixture.events().isEmpty)
    #expect(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue) == nil)
    #expect(await primary.callCount == 0)
}

// MARK: - Writing summary.json

/// A directory already sitting at `summary.json` makes the atomic rename
/// fail, so the write fails without any test-only seam in the stage.
@Test func summaryWriteFailureFailsWithSummaryWriteFailedAndRecordsNoTelemetry() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let summaryURL = try fixture.summaryURL()
    try FileManager.default.createDirectory(at: summaryURL, withIntermediateDirectories: true)

    let outcome = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded())))

    guard case let .failed(targetState, errorClass, errorMessage, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .summarizationFailed)
    #expect(errorClass == "summary_write_failed")
    #expect(errorMessage == "summaryWriteFailed")
    #expect(SummarizeStage.exitCode(for: outcome) == 2)
    #expect(try await fixture.state() == "summarization_failed")
    #expect(try await fixture.events().map(\.event) == ["started", "failed"])
    #expect(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue) == nil)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: summaryURL.path, isDirectory: &isDirectory) && isDirectory.boolValue)
}
