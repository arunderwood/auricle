import AIReviewerInterface
@testable import Core
import Foundation
import GRDB
import Orchestrator
@testable import ReviewDiarization
@testable import State
import Testing

private let enabledSettings = ReviewDiarizationSettings(enabled: true, modelID: "claude-haiku-4-5", timeoutSeconds: 5)

private func expectStub(_ fixture: ReviewFixture, model: String) throws {
    let stub = try fixture.readSuggestions()
    #expect(stub.suggestions.isEmpty)
    #expect(stub.cost.costUSD == 0)
    #expect(stub.cost.inputTokens == 0)
    #expect(stub.cost.modelID == model)
    #expect(stub.schemaVersion == 1)
}

@Test func flagOffWritesStubWithoutReadingOrCallingTheReviewer() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    let reviewer = StubReviewer(.succeed(stubResult(suggestions: [stubSuggestion("a")])))

    // The fastest of several runs: a suite running in parallel can stall any
    // single one, and the budget is about what the stage costs, not the host.
    var elapsed = Duration.seconds(60)
    for _ in 0 ..< 5 {
        let attempt = try await ReviewFixture()
        defer { attempt.cleanUp() }
        let started = ContinuousClock.now
        _ = try await attempt.run(reviewer: reviewer, settings: ReviewDiarizationSettings(enabled: false))
        elapsed = min(elapsed, ContinuousClock.now - started)
    }
    let outcome = try await fixture.run(reviewer: reviewer, settings: ReviewDiarizationSettings(enabled: false))

    #expect(elapsed < .milliseconds(100))
    #expect(await reviewer.callCount == 0)
    guard case let .completed(target, metadataJSON) = outcome else {
        Issue.record("expected completed, got \(outcome)")
        return
    }
    #expect(target == .awaitingAttribution)
    #expect(ReviewDiarizationStage.exitCode(for: outcome) == 0)
    try expectStub(fixture, model: "flag_off")

    let events = try await fixture.events()
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(events.allSatisfy { $0.stage == "review-diarization" })
    let meta = try #require(metadataJSON)
    #expect(meta == events.last?.metadataJSON)
    let object = try metadataObject(#require(events.last))
    #expect(object["model_id"] as? String == "flag_off")
    #expect(object["review_skipped"] as? Bool == true)
    #expect(object["suggestions_count"] as? Int == 0)
    #expect(object["cost_usd"] as? Double == 0)
    #expect(object["input_tokens"] as? Int == 0)

    let telemetry = try #require(await fixture.telemetry())
    #expect(telemetry.diarizationSuggestionsCount == 0)
    #expect(telemetry.diarizationReviewCostUSD == 0)
    #expect(telemetry.diarizationReviewModel == "flag_off")
    #expect(try await fixture.state() == "awaiting_attribution")
}

@Test func suggestionsFileIsOwnerOnlyWithSchemaVersion() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }

    _ = try await fixture.run(reviewer: StubReviewer(.succeed(stubResult(suggestions: []))), settings: ReviewDiarizationSettings())

    let path = try fixture.url("diarization_suggestions.json").path
    let permissions = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    #expect(permissions == 0o600)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    #expect(object["schema_version"] as? Int == 1)
}

@Test func flagOnWritesTheReviewersSuggestionsAndCost() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    let reviewer = StubReviewer(.succeed(stubResult(suggestions: [stubSuggestion("a"), stubSuggestion("b")])))

    let outcome = try await fixture.run(reviewer: reviewer, settings: enabledSettings)

    #expect(await reviewer.lastConfig == AIReviewerConfig(modelID: "claude-haiku-4-5"))
    guard case .completed(.awaitingAttribution, _) = outcome else {
        Issue.record("expected completed, got \(outcome)")
        return
    }
    #expect(ReviewDiarizationStage.exitCode(for: outcome) == 0)
    let written = try fixture.readSuggestions()
    #expect(written.suggestions.map(\.suggestionId) == ["a", "b"])
    #expect(written.reviewedSegmentCount == 4)

    let object = try await metadataObject(#require(fixture.events().last))
    #expect(object["model_id"] as? String == "claude-haiku-4-5")
    #expect(object["input_tokens"] as? Int == 1200)
    #expect(object["output_tokens"] as? Int == 80)
    #expect(object["cost_usd"] as? Double == 0.03)
    #expect(object["suggestions_count"] as? Int == 2)
    #expect(object["review_skipped"] as? Bool == false)

    let telemetry = try #require(await fixture.telemetry())
    #expect(telemetry.diarizationSuggestionsCount == 2)
    #expect(telemetry.diarizationReviewCostUSD == 0.03)
    #expect(telemetry.diarizationReviewModel == "claude-haiku-4-5")
}

@Test func zeroSuggestionsIsNotASkippedReview() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()

    let outcome = try await fixture.run(reviewer: StubReviewer(.succeed(stubResult(suggestions: []))), settings: enabledSettings)

    guard case .completed = outcome else {
        Issue.record("expected completed, got \(outcome)")
        return
    }
    #expect(try fixture.readSuggestions().suggestions.isEmpty)
    let object = try await metadataObject(#require(fixture.events().last))
    #expect(object["review_skipped"] as? Bool == false)
    #expect(object["suggestions_count"] as? Int == 0)
}

@Test func timeoutWritesStubAndAdvances() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    let reviewer = StubReviewer(.hang(seconds: 30))

    let started = ContinuousClock.now
    let outcome = try await fixture.run(reviewer: reviewer, settings: ReviewDiarizationSettings(enabled: true, timeoutSeconds: 0.2))

    #expect(ContinuousClock.now - started < .seconds(5))
    try await expectBenignFailure(outcome, fixture: fixture, errorClass: "ai_reviewer_timeout")
}

@Test func reviewerErrorWritesStubAndNeverRecordsItsText() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    let reviewer = StubReviewer(.fail(LeakyReviewerError(secret: "TOP-SECRET-TRANSCRIPT")))

    let outcome = try await fixture.run(reviewer: reviewer, settings: enabledSettings)

    try await expectBenignFailure(outcome, fixture: fixture, errorClass: "ai_reviewer_failed")
    let event = try #require(await fixture.events().last)
    #expect(event.errorMessage?.contains("TOP-SECRET") == false)
    #expect(event.metadataJSON?.contains("TOP-SECRET") == false)
}

@Test func missingInputsWriteStubWithoutCallingTheReviewer() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    let reviewer = StubReviewer(.succeed(stubResult(suggestions: [stubSuggestion("a")])))

    let outcome = try await fixture.run(reviewer: reviewer, settings: enabledSettings)

    #expect(await reviewer.callCount == 0)
    try await expectBenignFailure(outcome, fixture: fixture, errorClass: "review_inputs_unreadable")
}

@Test func undecodableInputsWriteStub() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    try AtomicWriter.write(Data("not json".utf8), to: fixture.url("diarization.json"))

    let outcome = try await fixture.run(reviewer: StubReviewer(.succeed(stubResult(suggestions: []))), settings: enabledSettings)

    try await expectBenignFailure(outcome, fixture: fixture, errorClass: "review_inputs_unreadable")
}

@Test func failedStubWriteRecordsWriteFailureAndStillAdvances() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    let directory = try fixture.url("diarization_suggestions.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try AtomicWriter.write(Data("x".utf8), to: directory.appendingPathComponent("blocker"))

    let outcome = try await fixture.run(reviewer: StubReviewer(.succeed(stubResult(suggestions: []))), settings: ReviewDiarizationSettings())

    guard case let .failed(target, errorClass, _, _) = outcome else {
        Issue.record("expected failed, got \(outcome)")
        return
    }
    #expect(target == .awaitingAttribution)
    #expect(errorClass == "suggestions_write_failed")
    #expect(ReviewDiarizationStage.exitCode(for: outcome) == 2)
    #expect(try await fixture.state() == "awaiting_attribution")
    #expect(try await fixture.telemetry() == nil)
}

@Test func writeFailureAfterASuccessfulReviewStillRecordsTheSpend() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    let target = try fixture.url("diarization_suggestions.json")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try AtomicWriter.write(Data("x".utf8), to: target.appendingPathComponent("blocker"))
    let reviewer = StubReviewer(.succeed(stubResult(suggestions: [stubSuggestion("a")], model: "billed-model")))

    let outcome = try await fixture.run(reviewer: reviewer, settings: enabledSettings)

    guard case let .failed(_, errorClass, _, _) = outcome else {
        Issue.record("expected failed, got \(outcome)")
        return
    }
    #expect(errorClass == "suggestions_write_failed")
    let telemetry = try #require(await fixture.telemetry())
    #expect(telemetry.diarizationSuggestionsCount == 0)
    #expect(telemetry.diarizationReviewCostUSD == 0.03)
    #expect(telemetry.diarizationReviewModel == "billed-model")
}

@Test func workerExitsWithStateErrorWhenTheStoreFailsUnderneathTheStage() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    try await fixture.queue.write { try $0.execute(sql: "DROP TABLE stage_events") }

    let exit = await ReviewDiarizationWorker.run(
        meetingID: fixture.meetingID,
        stateStore: fixture.store,
        stageRunner: fixture.runner,
        reviewer: StubReviewer(.fail(LeakyReviewerError(secret: ""))),
        settings: ReviewDiarizationSettings(),
    )

    #expect(exit.code == WorkerExitCode.stateError)
}

@Test func unknownMeetingThrowsAndRecordsNothing() async throws {
    let fixture = try await ReviewFixture(insertMeetingRow: false)
    defer { fixture.cleanUp() }

    await #expect(throws: StateStoreError.meetingNotFound(id: fixture.meetingID.rawValue)) {
        _ = try await fixture.run(reviewer: StubReviewer(.fail(LeakyReviewerError(secret: ""))), settings: enabledSettings)
    }
    #expect(try await fixture.events().isEmpty)
}

@Test func workerMapsUnknownMeetingToExit3AndSuccessToZero() async throws {
    let missing = try await ReviewFixture(insertMeetingRow: false)
    defer { missing.cleanUp() }
    let stub = StubReviewer(.fail(LeakyReviewerError(secret: "")))
    let unknown = await ReviewDiarizationWorker.run(meetingID: missing.meetingID, stateStore: missing.store, stageRunner: missing.runner, reviewer: stub, settings: enabledSettings)
    #expect(unknown.code == WorkerExitCode.meetingNotFound)

    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    let success = await ReviewDiarizationWorker.run(
        meetingID: fixture.meetingID,
        stateStore: fixture.store,
        stageRunner: fixture.runner,
        reviewer: stub,
        settings: ReviewDiarizationSettings(),
    )
    #expect(success.code == 0)
    #expect(try await fixture.state() == "awaiting_attribution")
}

@Test func telemetryFailureDoesNotFailTheStage() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    try await fixture.queue.write { try $0.execute(sql: "DROP TABLE telemetry") }

    let outcome = try await fixture.run(reviewer: StubReviewer(.succeed(stubResult(suggestions: []))), settings: ReviewDiarizationSettings())

    guard case .completed = outcome else {
        Issue.record("expected completed, got \(outcome)")
        return
    }
    #expect(try await fixture.state() == "awaiting_attribution")
}

@Test func immutableInputsAreNeverModified() async throws {
    let fixture = try await ReviewFixture()
    defer { fixture.cleanUp() }
    let before = try fixture.plantInputs()

    _ = try await fixture.run(reviewer: StubReviewer(.succeed(stubResult(suggestions: [stubSuggestion("a")]))), settings: enabledSettings)

    #expect(try Data(contentsOf: fixture.url("transcript.json")) == before.transcript)
    #expect(try Data(contentsOf: fixture.url("diarization.json")) == before.diarization)
}

@Test func settingsDefaultToFlagOffAndFallBackOnUnreadableConfig() throws {
    #expect(ReviewDiarizationSettings() == ReviewDiarizationSettings(enabled: false, modelID: "claude-haiku-4-5", timeoutSeconds: 90))

    var reported = false
    let fallback = ReviewDiarizationSettings.loading(config: { throw ConfigError.malformed(line: 1) }, onFailure: { _ in reported = true })
    #expect(fallback.enabled == false)
    #expect(reported)

    let loaded = try ReviewDiarizationSettings.loading(config: { try Config.parse("[diarization_review]\nenabled = true\nmodel = \"m\"\n") })
    #expect(loaded.enabled)
    #expect(loaded.modelID == "m")
}

private func expectBenignFailure(_ outcome: StageRunner.StageOutcome, fixture: ReviewFixture, errorClass expected: String) async throws {
    guard case let .failed(target, errorClass, _, _) = outcome else {
        Issue.record("expected failed, got \(outcome)")
        return
    }
    #expect(target == .awaitingAttribution)
    #expect(errorClass == expected)
    #expect(ReviewDiarizationStage.exitCode(for: outcome) == 0)
    try expectStub(fixture, model: "claude-haiku-4-5")
    #expect(try await fixture.state() == "awaiting_attribution")
    let events = try await fixture.events()
    #expect(events.map(\.event) == ["started", "failed"])
    #expect(try metadataObject(#require(events.last))["error_class"] as? String == expected)
    let telemetry = try #require(await fixture.telemetry())
    #expect(telemetry.diarizationSuggestionsCount == 0)
    #expect(telemetry.diarizationReviewCostUSD == 0)
    #expect(telemetry.diarizationReviewModel == "claude-haiku-4-5")
}
