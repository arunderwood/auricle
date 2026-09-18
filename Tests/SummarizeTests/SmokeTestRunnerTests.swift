import Core
import Foundation
import Summarize
import SummarizerInterface
import Testing

// MARK: - Stub strategies

private func makeSummary(
    method: GroundingMethod,
    actionItemCount: Int = 0,
    dropCount: Int = 0,
    costUSD: Double = 0.01,
) -> SummaryWithGrounding {
    let items = (0 ..< actionItemCount).map { index in
        GroundedItem(
            text: "item \(index)",
            grounding: GroundingPointer(transcriptStart: 0, transcriptEnd: 1, sourceMethod: method),
        )
    }
    return SummaryWithGrounding(
        schemaVersion: 1,
        summary: "summary",
        actionItems: items,
        decisions: [],
        groundingMethod: method,
        cost: SummarizerCost(inputTokens: 10, outputTokens: 5, thinkingTokens: 2, costUSD: costUSD),
        quoteValidationDropCount: dropCount,
    )
}

private struct FixedStrategy: SummarizerStrategy {
    let outcome: Result<SummaryWithGrounding, any Error>
    var delay: Duration = .zero

    func summarize(transcript _: CanonicalTranscript, glossary _: Glossary, config _: SummarizerConfig) async throws -> SummaryWithGrounding {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try outcome.get()
    }
}

/// Counts how many strategies have started, so two strategies can each wait
/// for the other and only finish if they genuinely overlap.
private actor Rendezvous {
    private var started = 0

    func arrive() {
        started += 1
    }

    func bothStarted() -> Bool {
        started >= 2
    }
}

/// Tracks how many strategy calls are in flight at once and the highest that
/// count ever reached.
private actor InFlightTracker {
    private var inFlight = 0
    private(set) var peak = 0

    func begin() {
        inFlight += 1
        peak = max(peak, inFlight)
    }

    func end() {
        inFlight -= 1
    }
}

private struct TrackedStrategy: SummarizerStrategy {
    let tracker: InFlightTracker
    let summary: SummaryWithGrounding

    func summarize(transcript _: CanonicalTranscript, glossary _: Glossary, config _: SummarizerConfig) async throws -> SummaryWithGrounding {
        await tracker.begin()
        try await Task.sleep(for: .milliseconds(30))
        await tracker.end()
        return summary
    }
}

private struct RendezvousTimeout: Error {}

private struct RendezvousStrategy: SummarizerStrategy {
    let rendezvous: Rendezvous
    let summary: SummaryWithGrounding

    func summarize(transcript _: CanonicalTranscript, glossary _: Glossary, config _: SummarizerConfig) async throws -> SummaryWithGrounding {
        await rendezvous.arrive()
        let deadline = ContinuousClock.now + .seconds(3)
        while await !rendezvous.bothStarted() {
            if ContinuousClock.now > deadline {
                throw RendezvousTimeout()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return summary
    }
}

/// An error whose message must never reach a report.
private struct LeakyError: Error, LocalizedError, CustomStringConvertible {
    var errorDescription: String? {
        "SECRET-MESSAGE"
    }

    var description: String {
        "SECRET-MESSAGE"
    }
}

private func makeFixture(_ name: String) -> SmokeTestFixture {
    SmokeTestFixture(name: name, transcript: CanonicalTranscript(text: "Ada: hello", utterances: []))
}

private func run(_ arms: [SmokeTestArm], fixtures: [SmokeTestFixture]) async -> [SmokeTestRow] {
    await SmokeTestRunner(arms: arms).run(fixtures: fixtures, glossary: Glossary(), config: SummarizerConfig())
}

// MARK: - I/O matrix

struct SmokeTestRunnerTests {
    @Test func bothArmsSucceedRecordsEachArmInGivenOrderPerTranscript() async {
        // The first arm is the slower one, so arm order in the result can only
        // come from the order given, not from completion order.
        let slow = FixedStrategy(
            outcome: .success(makeSummary(method: .citations, actionItemCount: 2, costUSD: 0.5)),
            delay: .milliseconds(60),
        )
        let fast = FixedStrategy(outcome: .success(makeSummary(method: .substring, actionItemCount: 1, dropCount: 1, costUSD: 0.25)))
        let arms = [SmokeTestArm(label: "citations", strategy: slow), SmokeTestArm(label: "substring", strategy: fast)]

        let rows = await run(arms, fixtures: [makeFixture("one"), makeFixture("two")])

        #expect(rows.map(\.name) == ["one", "two"])
        for row in rows {
            #expect(row.arms.map(\.label) == ["citations", "substring"])
            guard case let .summary(first) = row.arms[0].outcome, case let .summary(second) = row.arms[1].outcome else {
                Issue.record("expected both arms to succeed")
                return
            }
            #expect(first.groundingMethod == .citations)
            #expect(first.actionItems.count == 2)
            #expect(first.quoteValidationDropCount == 0)
            #expect(first.cost.costUSD == 0.5)
            #expect(second.groundingMethod == .substring)
            #expect(second.actionItems.count == 1)
            #expect(second.quoteValidationDropCount == 1)
            #expect(second.cost.costUSD == 0.25)
        }
    }

    @Test func armThrowingSummarizerErrorIsRecordedByCaseAndOtherArmIsUnaffected() async {
        let failing = FixedStrategy(outcome: .failure(SummarizerError.citationsUnavailable))
        let working = FixedStrategy(outcome: .success(makeSummary(method: .substring)))
        let arms = [SmokeTestArm(label: "citations", strategy: failing), SmokeTestArm(label: "substring", strategy: working)]

        let rows = await run(arms, fixtures: [makeFixture("one"), makeFixture("two")])

        #expect(rows.count == 2)
        for row in rows {
            #expect(row.arms[0].outcome == .failure(reason: "SummarizerError.citationsUnavailable"))
            #expect(row.arms[1].outcome == .summary(makeSummary(method: .substring)))
        }
    }

    @Test func armThrowingOtherErrorIsRecordedByTypeNameNeverMessage() async {
        let failing = FixedStrategy(outcome: .failure(LeakyError()))
        let arms = [SmokeTestArm(label: "leaky", strategy: failing)]

        let rows = await run(arms, fixtures: [makeFixture("one")])

        guard case let .failure(reason) = rows[0].arms[0].outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(reason.contains("LeakyError"))
        #expect(!reason.contains("SECRET"))
    }

    @Test func armsOfOneTranscriptRunConcurrently() async {
        let rendezvous = Rendezvous()
        let arms = [
            SmokeTestArm(label: "a", strategy: RendezvousStrategy(rendezvous: rendezvous, summary: makeSummary(method: .citations))),
            SmokeTestArm(label: "b", strategy: RendezvousStrategy(rendezvous: rendezvous, summary: makeSummary(method: .substring))),
        ]

        let rows = await run(arms, fixtures: [makeFixture("one")])

        // Serial execution makes the first arm wait out its timeout alone and
        // record a failure, so this fails within seconds rather than hanging.
        #expect(rows[0].arms.map(\.outcome) == [
            .summary(makeSummary(method: .citations)),
            .summary(makeSummary(method: .substring)),
        ])
    }

    @Test func transcriptsRunOneAfterAnotherSoOnlyTheArmsOfOneTranscriptOverlap() async {
        let tracker = InFlightTracker()
        let arms = [
            SmokeTestArm(label: "a", strategy: TrackedStrategy(tracker: tracker, summary: makeSummary(method: .citations))),
            SmokeTestArm(label: "b", strategy: TrackedStrategy(tracker: tracker, summary: makeSummary(method: .substring))),
        ]

        let rows = await run(arms, fixtures: [makeFixture("one"), makeFixture("two"), makeFixture("three")])

        #expect(rows.count == 3)
        // 2 means the arms of a transcript overlapped and no transcript did;
        // 6 would mean the runner fanned out across transcripts too.
        #expect(await tracker.peak == 2)
    }

    @Test func plannedCallCountIsFixturesTimesArms() {
        let runner = SmokeTestRunner(arms: [
            SmokeTestArm(label: "a", strategy: FixedStrategy(outcome: .success(makeSummary(method: .citations)))),
            SmokeTestArm(label: "b", strategy: FixedStrategy(outcome: .success(makeSummary(method: .substring)))),
        ])

        #expect(runner.plannedCallCount(fixtureCount: 5) == 10)
        #expect(runner.plannedCallCount(fixtureCount: 0) == 0)
    }
}
