import ClaudeSummarizer
import Core
import Foundation
import Persist
@testable import Summarize
import SummarizerInterface
import Testing

/// Runs every fixture under `Fixtures/eval/` through the real strategies,
/// validators, orchestrator, mapper and renderer against stubbed Anthropic
/// responses, then scores the rendered result against `expected.json`.
///
/// It measures the validators, the grounding-to-artifact mapping and the
/// note renderer. It cannot measure prompt quality: the stubs never read the
/// request, so a prompt change moves nothing here.
struct SummarizeEvalHarness {
    @Test func atLeastFiveFixturesExist() {
        #expect(EvalFixtures.names.count >= 5)
    }

    @Test(arguments: EvalFixtures.names)
    func shippedCompositionKeepsEveryExpectedItemAndDropsEveryDecoy(name: String) async throws {
        let fixture = try EvalFixtures.load(name)
        let decoys = try EvalStubResponses.decoys(for: fixture.transcript)
        let stub = try EvalStub(response: EvalStubResponses.substring(for: fixture, decoys: decoys))
        defer { stub.release() }

        let outcome = try await summarizeAsShipped(fixture.transcript, client: stub.client)

        #expect(!outcome.fallbackTriggered)
        #expect(outcome.primaryError == nil)
        #expect(outcome.summary.groundingMethod == .substring)
        #expect(outcome.summary.quoteValidationDropCount == decoys.count)
        #expect(stub.requestCount == 1)

        let score = try scoreRun(fixture, summary: outcome.summary, decoys: decoys)
        #expect(score.keptCount == score.expectedCount)
        #expect(score.survivedCount == score.expectedCount)
    }

    /// A malformed answer is a fallback-eligible failure. With no fallback
    /// it must surface after one call; a second call means the composition
    /// grew a fallback the harness's other runs would never exercise.
    @Test func shippedCompositionSurfacesAFallbackEligibleFailureAfterOneCall() async throws {
        let fixture = try EvalFixtures.load(#require(EvalFixtures.names.first))
        let stub = EvalStub(response: Data("not a messages response".utf8))
        defer { stub.release() }

        let error = await #expect(throws: SummarizerError.self) {
            try await summarizeAsShipped(fixture.transcript, client: stub.client)
        }

        #expect(error?.isFallbackEligible == true)
        #expect(stub.requestCount == 1)
    }

    @Test(arguments: EvalFixtures.names)
    func citationsStrategyKeepsEveryExpectedItem(name: String) async throws {
        let fixture = try EvalFixtures.load(name)
        let stub = try EvalStub(response: EvalStubResponses.citations(for: fixture))
        defer { stub.release() }

        let summary = try await ClaudeCitationsSummarizer(httpClient: stub.client)
            .summarize(transcript: fixture.transcript, glossary: Glossary(), config: SummarizerConfig())

        #expect(summary.groundingMethod == .citations)

        let score = try scoreRun(fixture, summary: summary, decoys: [])
        #expect(score.keptCount == score.expectedCount)
        #expect(score.survivedCount == score.expectedCount)
    }

    @Test(arguments: EvalFixtures.names)
    func substringArmDropsEveryDecoyAndKeepsEveryExpectedItem(name: String) async throws {
        let fixture = try EvalFixtures.load(name)
        let decoys = try EvalStubResponses.decoys(for: fixture.transcript)
        let stub = try EvalStub(response: EvalStubResponses.substring(for: fixture, decoys: decoys))
        defer { stub.release() }

        let summary = try await ClaudeSubstringSummarizer(httpClient: stub.client)
            .summarize(transcript: fixture.transcript, glossary: Glossary(), config: SummarizerConfig())

        #expect(summary.groundingMethod == .substring)
        #expect(summary.quoteValidationDropCount == decoys.count)

        let score = try scoreRun(fixture, summary: summary, decoys: decoys)
        #expect(score.keptCount == score.expectedCount)
        #expect(score.survivedCount == score.expectedCount)
    }
}

// MARK: - Shipped wiring

/// The only way the harness builds an orchestrator: `ShippedSummarization` is
/// what `InternalStageWorker` runs, so every result here describes what ships.
private func summarizeAsShipped(
    _ transcript: CanonicalTranscript,
    client: AnthropicHTTPClient,
) async throws -> SummarizerOrchestrator.Outcome {
    try await ShippedSummarization.orchestrator(httpClient: client)
        .summarize(transcript: transcript, glossary: Glossary(), config: SummarizerConfig())
}

// MARK: - Run pipeline

/// Maps and renders `summary` the way the summarize and persist stages do,
/// scores the note, prints the audit line, and records every failed check.
/// `decoys` are the ones the substring stub was given; they only count as
/// emitted when the strategy that produced `summary` is the substring one.
private func scoreRun(_ fixture: EvalFixture, summary: SummaryWithGrounding, decoys: [EvalDecoy]) throws -> EvalScore {
    let note = try renderedNote(fixture, summary: summary)
    let emitted = summary.groundingMethod == .substring ? decoys : []
    let score = EvalScorer.score(fixture: fixture, summary: summary, decoys: emitted, note: note)

    print(score.summaryLine)
    #expect(score.failures.isEmpty, Comment(rawValue: "\(fixture.name): \(score.failures.joined(separator: "; "))"))
    return score
}

private func renderedNote(_ fixture: EvalFixture, summary: SummaryWithGrounding) throws -> String {
    let transcript = fixture.transcript
    let bytes = Array(transcript.text.utf8)
    let segments = try SummaryArtifactMapper.transcriptSegments(of: transcript, transcriptBytes: bytes, speakers: nil)
    let artifact = try SummaryArtifactMapper.artifact(
        title: "Eval fixture \(fixture.name)",
        grounded: summary,
        transcriptSegments: segments,
        needsAttribution: SummaryArtifactMapper.needsAttribution(transcript: transcript, speakers: nil),
        transcriptBytes: bytes,
    )
    return FrontmatterRenderer.render(meeting: frontmatterMeeting(artifact))
}

/// Field-for-field the same mapping `PersistStage` applies to a decoded
/// `summary.json`; that function is private, so this is its test-side twin.
private func frontmatterMeeting(_ artifact: SummaryArtifact) -> MeetingForFrontmatter {
    MeetingForFrontmatter(
        meetingID: MeetingID(ulid: "01HJK3PQXY7N8M3FT4QHNWVZRP")!,
        title: artifact.title,
        date: "2026-01-15",
        attendees: artifact.attendees,
        schemaVersion: 1,
        supersedes: nil,
        needsAttribution: artifact.needsAttribution,
        needsCalendarEnrichment: artifact.needsCalendarEnrichment,
        summary: artifact.summary,
        actionItems: artifact.actionItems.map { QuotedItem(text: $0.text, quote: $0.quote) },
        decisions: artifact.decisions.map { QuotedItem(text: $0.text, quote: $0.quote) },
        transcriptSegments: artifact.transcriptSegments.map { TranscriptSegment(speaker: $0.speaker, text: $0.text) },
        audioPath: nil,
        calendarEventID: nil,
        retentionPolicy: nil,
    )
}
