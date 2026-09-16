import Foundation
import Testing
@testable import Telemetry

private func roundTrip(_ metadata: StageMetadata) throws -> StageMetadata {
    let encoded = try JSONEncoder().encode(metadata)
    return try JSONDecoder().decode(StageMetadata.self, from: encoded)
}

@Test func captureMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.capture(CaptureMeta())
    #expect(try roundTrip(original) == original)
}

@Test func transcribeMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.transcribe(TranscribeMeta(
        modelID: "whisper-large-v3-turbo",
        audioDurationSeconds: 1827,
        transcriptChars: 23847
    ))
    #expect(try roundTrip(original) == original)
}

@Test func reviewDiarizationMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.reviewDiarization(ReviewDiarizationMeta(
        modelID: "claude-haiku-4-5",
        inputTokens: 512,
        outputTokens: 128,
        costUSD: 0.004,
        suggestionsCount: 3,
        reviewSkipped: false
    ))
    #expect(try roundTrip(original) == original)
}

/// The flag-off contract (Decision 5.6/AR-AI-2) is the same `ReviewDiarizationMeta`
/// shape, not a distinct case — worth its own fixture since `costUSD: 0` and
/// `suggestionsCount: 0` are the values production actually writes when
/// `diarization_review.enabled = false`.
@Test func reviewDiarizationMetaFlagOffRoundTripsLosslessly() throws {
    let original = StageMetadata.reviewDiarization(ReviewDiarizationMeta(
        modelID: "flag_off",
        inputTokens: 0,
        outputTokens: 0,
        costUSD: 0,
        suggestionsCount: 0,
        reviewSkipped: true
    ))
    #expect(try roundTrip(original) == original)
}

@Test func attributeMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.attribute(AttributeMeta())
    #expect(try roundTrip(original) == original)
}

@Test func summarizeMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.summarize(SummarizeMeta(
        modelID: "claude-opus-5",
        effortBudget: "medium",
        inputTokens: 4200,
        outputTokens: 900,
        thinkingTokens: 1200,
        costUSD: 0.32,
        quoteValidationDropCount: 2,
        groundingMethod: "citations"
    ))
    #expect(try roundTrip(original) == original)
}

@Test func persistMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.persist(PersistMeta(
        vaultNotePath: "/Users/testuser/ObsidianVault/Meetings/2026-01-01 Tuesday Sync.md",
        frontmatterSchemaVersion: 1
    ))
    #expect(try roundTrip(original) == original)
}

@Test func notifyMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.notify(NotifyMeta(notificationID: "01HJK3PQXY7N8M0000000000", delivered: true))
    #expect(try roundTrip(original) == original)
}

/// `capture`/`attribute`'s placeholder payloads both encode to `{}` — the
/// case must still round-trip through its own key, not collapse into
/// whichever placeholder case happens to be tried first.
@Test func captureAndAttributePlaceholdersAreNotInterchangeableDespiteIdenticalContent() throws {
    let capture = StageMetadata.capture(CaptureMeta())
    let attribute = StageMetadata.attribute(AttributeMeta())

    #expect(try roundTrip(capture) == capture)
    #expect(try roundTrip(attribute) == attribute)
    #expect(capture != attribute)
}
