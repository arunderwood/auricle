import Core
import Summarize
import SummarizerInterface
import Testing

// MARK: - Stub strategy

/// A `SummarizerStrategy` double configurable to either return a fixed
/// `SummaryWithGrounding` or throw a given `SummarizerError`, and to record
/// whether it was invoked — the primary/fallback tests need to assert not
/// just what `SummarizerOrchestrator` returns but which strategy it called.
private actor StubSummarizerStrategy: SummarizerStrategy {
    enum Behavior {
        case succeed(SummaryWithGrounding)
        case fail(SummarizerError)
        case failWithError(any Error)
    }

    private let behavior: Behavior
    private(set) var callCount = 0
    private(set) var receivedTranscript: CanonicalTranscript?
    private(set) var receivedGlossary: Glossary?
    private(set) var receivedConfig: SummarizerConfig?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func summarize(
        transcript: CanonicalTranscript,
        glossary: Glossary,
        config: SummarizerConfig,
    ) async throws -> SummaryWithGrounding {
        callCount += 1
        receivedTranscript = transcript
        receivedGlossary = glossary
        receivedConfig = config
        switch behavior {
        case let .succeed(summary):
            return summary
        case let .fail(error):
            throw error
        case let .failWithError(error):
            throw error
        }
    }
}

/// A non-`SummarizerError` `Error` conformer, to prove the orchestrator's
/// `catch let primaryError as SummarizerError` pattern lets an error of a
/// different type rethrow unmatched rather than only handling `SummarizerError`.
private struct OtherStrategyError: Error, Equatable {}

// MARK: - Fixtures

private func makeTranscript() -> CanonicalTranscript {
    CanonicalTranscript(text: "", utterances: [])
}

private func makeSummary(groundingMethod: GroundingMethod) -> SummaryWithGrounding {
    SummaryWithGrounding(
        schemaVersion: 1,
        summary: "summary",
        actionItems: [],
        decisions: [],
        groundingMethod: groundingMethod,
        cost: SummarizerCost(inputTokens: 0, outputTokens: 0, thinkingTokens: 0, costUSD: 0),
        quoteValidationDropCount: 0,
    )
}

// MARK: - I/O matrix

@Test func primarySucceedsReturnsFallbackTriggeredFalseAndNeverCallsFallback() async throws {
    let primary = StubSummarizerStrategy(behavior: .succeed(makeSummary(groundingMethod: .citations)))
    let fallback = StubSummarizerStrategy(behavior: .succeed(makeSummary(groundingMethod: .substring)))
    let orchestrator = SummarizerOrchestrator(primary: primary, fallback: fallback)

    let outcome = try await orchestrator.summarize(transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig())

    #expect(outcome.fallbackTriggered == false)
    #expect(outcome.primaryError == nil)
    #expect(outcome.summary.groundingMethod == .citations)
    #expect(await primary.callCount == 1)
    #expect(await fallback.callCount == 0)
}

@Test func primaryThrowsFallbackEligibleAndFallbackSucceedsReturnsFallbackOutcome() async throws {
    let primary = StubSummarizerStrategy(behavior: .fail(.citationsUnavailable))
    let fallback = StubSummarizerStrategy(behavior: .succeed(makeSummary(groundingMethod: .substring)))
    let orchestrator = SummarizerOrchestrator(primary: primary, fallback: fallback)
    let transcript = makeTranscript()
    let glossary = Glossary()
    let config = SummarizerConfig()

    let outcome = try await orchestrator.summarize(transcript: transcript, glossary: glossary, config: config)

    #expect(outcome.fallbackTriggered == true)
    guard case .citationsUnavailable = outcome.primaryError else {
        Issue.record("expected primaryError to be .citationsUnavailable, got \(String(describing: outcome.primaryError))")
        return
    }
    #expect(outcome.summary.groundingMethod == .substring)
    #expect(await primary.callCount == 1)
    #expect(await fallback.callCount == 1)
    #expect(await fallback.receivedTranscript == transcript)
    #expect(await fallback.receivedGlossary == glossary)
    #expect(await fallback.receivedConfig == config)
}

@Test func primaryThrowsFallbackEligibleAndFallbackAlsoFailsRethrowsFallbackError() async throws {
    let primary = StubSummarizerStrategy(behavior: .fail(.malformedResponse))
    let fallback = StubSummarizerStrategy(behavior: .fail(.rateLimited))
    let orchestrator = SummarizerOrchestrator(primary: primary, fallback: fallback)

    await #expect(throws: SummarizerError.rateLimited) {
        try await orchestrator.summarize(transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig())
    }
    #expect(await primary.callCount == 1)
    #expect(await fallback.callCount == 1)
}

@Test func primaryThrowsNonFallbackEligibleRethrowsUnchangedAndNeverCallsFallback() async throws {
    let primary = StubSummarizerStrategy(behavior: .fail(.networkTimeout))
    let fallback = StubSummarizerStrategy(behavior: .succeed(makeSummary(groundingMethod: .substring)))
    let orchestrator = SummarizerOrchestrator(primary: primary, fallback: fallback)

    await #expect(throws: SummarizerError.networkTimeout) {
        try await orchestrator.summarize(transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig())
    }
    #expect(await primary.callCount == 1)
    #expect(await fallback.callCount == 0)
}

@Test func primaryThrowsNonSummarizerErrorRethrowsUnchangedAndNeverCallsFallback() async throws {
    let primary = StubSummarizerStrategy(behavior: .failWithError(OtherStrategyError()))
    let fallback = StubSummarizerStrategy(behavior: .succeed(makeSummary(groundingMethod: .substring)))
    let orchestrator = SummarizerOrchestrator(primary: primary, fallback: fallback)

    await #expect(throws: OtherStrategyError.self) {
        try await orchestrator.summarize(transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig())
    }
    #expect(await primary.callCount == 1)
    #expect(await fallback.callCount == 0)
}

@Test func noFallbackReturnsThePrimaryOutcome() async throws {
    let primary = StubSummarizerStrategy(behavior: .succeed(makeSummary(groundingMethod: .substring)))
    let orchestrator = SummarizerOrchestrator(primary: primary)

    let outcome = try await orchestrator.summarize(transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig())

    #expect(outcome.fallbackTriggered == false)
    #expect(outcome.primaryError == nil)
    #expect(outcome.summary.groundingMethod == .substring)
    #expect(await primary.callCount == 1)
}

@Test func noFallbackRethrowsAFallbackEligiblePrimaryErrorUnchanged() async throws {
    let primary = StubSummarizerStrategy(behavior: .fail(.malformedResponse))
    let orchestrator = SummarizerOrchestrator(primary: primary)

    await #expect(throws: SummarizerError.malformedResponse) {
        try await orchestrator.summarize(transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig())
    }
    #expect(await primary.callCount == 1)
}
