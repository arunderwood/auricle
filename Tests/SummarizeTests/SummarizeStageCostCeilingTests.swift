import Core
import Foundation
import Orchestrator
@testable import Summarize
import SummarizerInterface
import Testing

// MARK: - Recorded, never enforced

// The stub summary costs 0.32 USD, so a ceiling below, at and above that
// amount is over, exactly at, and under it.

@Test(arguments: [
    (0.31, true),
    (0.32, false),
    (0.50, false),
])
func theCeilingFlagIsSetOnlyWhenTheCostPassesIt(ceilingUSD: Double, expectedExceeded: Bool) async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let outcome = try await fixture.run(
        primary: StageStubStrategy(.success(makeStageGrounded())),
        config: SummarizerConfig(costCeilingUSD: ceilingUSD),
    )

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    let completed = try #require(try await fixture.events().last)
    let metadata = try stageMetadataObject(completed)
    #expect(metadata["cost_usd"] as? Double == 0.32)
    #expect(metadata["cost_ceiling_usd"] as? Double == ceilingUSD)
    #expect(metadata["cost_ceiling_exceeded"] as? Bool == expectedExceeded)
}

@Test func aRunOverTheCeilingStillKeepsTheSummaryTheTelemetryAndTheCompletedState() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    let outcome = try await fixture.run(
        primary: StageStubStrategy(.success(makeStageGrounded(summary: "Kept in full."))),
        config: SummarizerConfig(costCeilingUSD: 0.01),
    )

    #expect(SummarizeStage.exitCode(for: outcome) == 0)
    #expect(try fixture.readSummary().summary == "Kept in full.")
    #expect(try await fixture.state() == "summarizing")
    #expect(try await fixture.events().map(\.event) == ["started", "completed"])
    let telemetry = try #require(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue))
    #expect(telemetry.costUSD == 0.32)
}

@Test func theDefaultCeilingIsTheNFRC1DefaultTier() {
    #expect(SummarizerConfig().costCeilingUSD == 0.50)
}

// MARK: - The level sent is the level recorded

@Test func theEffortTheStrategyReceivesIsTheEffortTelemetryAndMetadataRecord() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    _ = try await fixture.run(primary: primary, config: SummarizerConfig(effortLevel: .xhigh))

    #expect(await primary.lastConfig?.effortLevel == .xhigh)
    let telemetry = try #require(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue))
    #expect(telemetry.summarizationEffortBudget == "xhigh")
    let completed = try #require(try await fixture.events().last)
    #expect(try stageMetadataObject(completed)["effort_budget"] as? String == "xhigh")
}

// MARK: - CostCeiling

@Test func aCostEqualToTheCeilingIsWithinIt() {
    #expect(!CostCeiling.isExceeded(costUSD: 0.5, ceilingUSD: 0.5))
    #expect(!CostCeiling.isExceeded(costUSD: 0.4999, ceilingUSD: 0.5))
    #expect(CostCeiling.isExceeded(costUSD: 0.5682, ceilingUSD: 0.5))
}

@Test func theWarningCarriesOnlyTheTwoAmounts() {
    let fields = CostCeiling.warningFields(costUSD: 0.5682, ceilingUSD: 0.5)

    #expect(Set(fields.keys) == ["costUSD", "costCeilingUSD"])
}
