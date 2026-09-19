import Core
import Foundation
import Orchestrator
@testable import Summarize
import SummarizerInterface
import Testing

// MARK: - Summarizer outcomes

@Test func fallbackWinningCompletesAndRecordsThePrimarysErrorClass() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.failure(SummarizerError.citationsUnavailable))
    let fallback = StageStubStrategy(.success(makeStageGrounded(method: .substring)))

    let outcome = try await fixture.run(primary: primary, fallback: fallback)

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(await primary.callCount == 1)
    #expect(await fallback.callCount == 1)
    let completed = try #require(try await fixture.events().last)
    let metadata = try stageMetadataObject(completed)
    #expect(metadata["grounding_method"] as? String == "substring")
    #expect(metadata["fallback_triggered"] as? Bool == true)
    #expect(metadata["fallback_error_class"] as? String == "summarizer_citations_unavailable")
    #expect(try fixture.readSummary().actionItems.map(\.quote) == [stageActionQuote])
}

@Test func bothStrategiesFailingReportsTheFallbacksError() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let outcome = try await fixture.run(
        primary: StageStubStrategy(.failure(SummarizerError.citationsUnavailable)),
        fallback: StageStubStrategy(.failure(SummarizerError.rateLimited)),
    )

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "summarizer_rate_limited")
    guard case let .failed(_, _, errorMessage, _) = outcome else { return }
    #expect(errorMessage == "rateLimited")
}

@Test func nonEligiblePrimaryErrorFailsWithoutCallingTheFallback() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let fallback = StageStubStrategy(.success(makeStageGrounded(method: .substring)))

    let outcome = try await fixture.run(primary: StageStubStrategy(.failure(SummarizerError.networkTimeout)), fallback: fallback)

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "summarizer_network_timeout")
    #expect(await fallback.callCount == 0)
}

@Test func aMissingAPIKeyFailsWithAMessageNamingTheFixAndNeverCallsTheFallback() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let fallback = StageStubStrategy(.success(makeStageGrounded(method: .substring)))

    let outcome = try await fixture.run(primary: StageStubStrategy(.failure(SummarizerError.apiKeyMissing)), fallback: fallback)

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "summarizer_api_key_missing")
    guard case let .failed(_, _, errorMessage, _) = outcome else { return }
    #expect(errorMessage?.contains("Keychain") == true)
    #expect(errorMessage?.contains("com.auricle.app.anthropic-api-key") == true)
    #expect(errorMessage?.contains("/") == false)
    #expect(await fallback.callCount == 0)
}

@Test func aTruncatedResponseFailsInItsOwnClassAndNeverCallsTheFallback() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let fallback = StageStubStrategy(.success(makeStageGrounded(method: .substring)))

    let outcome = try await fixture.run(primary: StageStubStrategy(.failure(SummarizerError.responseTruncated)), fallback: fallback)

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "summarizer_response_truncated")
    guard case let .failed(_, _, errorMessage, _) = outcome else { return }
    #expect(errorMessage == "responseTruncated")
    #expect(await fallback.callCount == 0)
}

@Test func aNonSummarizerErrorRecordsTheTypeNameAndNeverItsMessage() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let outcome = try await fixture.run(primary: StageStubStrategy(.failure(StageLeakyError(secret: "the launch codes"))))

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "summarize_unexpected_error")
    guard case let .failed(_, _, errorMessage, _) = outcome else { return }
    #expect(errorMessage?.contains("StageLeakyError") == true)
    #expect(errorMessage?.contains("the launch codes") == false)
    let failedEvent = try #require(try await fixture.events().last)
    #expect(failedEvent.metadataJSON?.contains("the launch codes") == false)
}

@Test func aPointerOutsideTheTranscriptFailsWithoutWritingASummary() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let badItem = GroundedItem(
        text: "Ungrounded",
        grounding: GroundingPointer(transcriptStart: 0, transcriptEnd: stageTranscriptText.utf8.count + 1, sourceMethod: .citations),
    )

    let outcome = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded(actionItems: [badItem]))))

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "quote_extraction_failed")
    #expect(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue) == nil)
}

// MARK: - Grounding method and prompt-set hash in telemetry

@Test func primaryAnsweringRecordsCitationsAndTheCitationsPromptSetHash() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let fallback = StageStubStrategy(.success(makeStageGrounded(method: .substring)))

    _ = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded(method: .citations))), fallback: fallback)

    let telemetry = try #require(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue))
    let citationsHash = try SummarizationPromptBuilder.promptSetHash(mode: .citations, promptDir: nil)
    #expect(telemetry.groundingMethod == "citations")
    #expect(telemetry.summarizationPromptSetHash == citationsHash)
    #expect(await fallback.callCount == 0)
}

@Test func fallbackAnsweringRecordsSubstringAndTheSubstringPromptSetHash() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    _ = try await fixture.run(
        primary: StageStubStrategy(.failure(SummarizerError.citationsUnavailable)),
        fallback: StageStubStrategy(.success(makeStageGrounded(method: .substring))),
    )

    let telemetry = try #require(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue))
    let substringHash = try SummarizationPromptBuilder.promptSetHash(mode: .substring, promptDir: nil)
    let citationsHash = try SummarizationPromptBuilder.promptSetHash(mode: .citations, promptDir: nil)
    #expect(telemetry.groundingMethod == "substring")
    #expect(telemetry.summarizationPromptSetHash == substringHash)
    #expect(telemetry.summarizationPromptSetHash != citationsHash)
}

@Test func aFailedRunLeavesNoGroundingMethodOrPromptSetHash() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    _ = try await fixture.run(primary: StageStubStrategy(.failure(SummarizerError.networkTimeout)))

    #expect(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue) == nil)
}

// MARK: - Prompt-set resolution happens before the paid call

/// The resolver fails for one mode only, so this also proves both modes are
/// resolved up front: the fallback's hash is needed only if the primary fails,
/// yet a broken fallback prompt must still stop the stage before the primary is paid for.
@Test(arguments: SummarizationMode.allCases)
func anUnresolvablePromptSetFailsTheStageBeforeEitherSummarizerIsCalled(failingMode: SummarizationMode) async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.success(makeStageGrounded()))
    let fallback = StageStubStrategy(.success(makeStageGrounded(method: .substring)))

    let outcome = try await fixture.run(primary: primary, fallback: fallback) { mode in
        if mode == failingMode {
            throw StageLeakyError(secret: "/private/prompt/path")
        }
        return "hash-\(mode.rawValue)"
    }

    try await expectStageFailure(outcome, fixture: fixture, errorClass: "prompt_set_unavailable")
    guard case let .failed(_, _, errorMessage, _) = outcome else { return }
    #expect(errorMessage == "promptSetUnavailable")
    #expect(await primary.callCount == 0)
    #expect(await fallback.callCount == 0)
    #expect(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue) == nil)
}

// MARK: - Re-run

@Test func rerunReplacesSummaryAtomicallyAndRecordsASecondEventPair() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    _ = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded(summary: "first"))))
    #expect(try fixture.readSummary().summary == "first")
    let outcome = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded(summary: "second"))))

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(try fixture.readSummary().summary == "second")
    let leftover = try AtomicWriter.temporaryURL(for: fixture.summaryURL())
    #expect(!FileManager.default.fileExists(atPath: leftover.path))
    #expect(try await fixture.events().map(\.event) == ["started", "completed", "started", "completed"])
    #expect(try await fixture.state() == "summarizing")
}

@Test func aFailedRunCanBeRetriedOnTheSameMeeting() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let summaryURL = try fixture.summaryURL()

    let failed = try await fixture.run(primary: StageStubStrategy(.failure(SummarizerError.networkTimeout)))

    guard case .failed = failed else {
        Issue.record("expected .failed outcome, got \(failed)")
        return
    }
    #expect(try await fixture.state() == "summarization_failed")
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))

    let retried = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded(summary: "retried"))))

    guard case .completed = retried else {
        Issue.record("expected .completed outcome, got \(retried)")
        return
    }
    #expect(try fixture.readSummary().summary == "retried")
    #expect(try await fixture.events().map(\.event) == ["started", "failed", "started", "completed"])
    #expect(try await fixture.state() == "summarizing")
}

// MARK: - Exit codes

@Test func exitCodeIsZeroForCompletedAndTwoForFailed() {
    #expect(SummarizeStage.exitCode(for: .completed(targetState: .summarizing)) == 0)
    #expect(SummarizeStage.exitCode(for: .failed(targetState: .summarizationFailed, errorClass: "x")) == 2)
}

// MARK: - Error class strings

/// Explicit literals, not derived from the case names: these strings are what
/// log queries and telemetry match on, so a rename or a swapped pair must fail here.
@Test(arguments: [
    (SummarizerError.citationsUnavailable, "summarizer_citations_unavailable"),
    (SummarizerError.malformedResponse, "summarizer_malformed_response"),
    (SummarizerError.rateLimited, "summarizer_rate_limited"),
    (SummarizerError.featureToggleDisabled, "summarizer_feature_toggle_disabled"),
    (SummarizerError.networkTimeout, "summarizer_network_timeout"),
    (SummarizerError.authenticationFailed, "summarizer_authentication_failed"),
    (SummarizerError.quotaExceeded, "summarizer_quota_exceeded"),
    (SummarizerError.responseTruncated, "summarizer_response_truncated"),
    (SummarizerError.apiKeyMissing, "summarizer_api_key_missing"),
])
func summarizerErrorClassStringsAreStable(error: SummarizerError, expectedClass: String) {
    #expect(error.stageErrorClass == expectedClass)
}
