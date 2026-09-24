import Foundation
@testable import Telemetry
import Testing

private func roundTrip(_ metadata: StageMetadata) throws -> StageMetadata {
    let encoded = try JSONEncoder().encode(metadata)
    return try JSONDecoder().decode(StageMetadata.self, from: encoded)
}

@Test func captureMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.capture(CaptureMeta())
    #expect(try roundTrip(original) == original)
}

@Test func captureMetaWithEveryFieldRoundTripsLosslesslyInSnakeCase() throws {
    let meta = CaptureMeta(
        micIncluded: true,
        exactZeroSeconds: 31.5,
        tapRebuilds: 2,
        reason: "recovered_after_interruption",
        errorClass: "permission_revoked_midstream",
        source: "microphone",
    )
    #expect(try roundTrip(.capture(meta)) == .capture(meta))

    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])
    #expect(Set(object.keys) == ["mic_included", "exact_zero_seconds", "tap_rebuilds", "reason", "error_class", "source"])
}

@Test func captureMetaSystemAudioLossFieldsRoundTripInSnakeCase() throws {
    let meta = CaptureMeta(
        micIncluded: true,
        systemAudioLostAt: "2026-09-22T10:05:00Z",
        systemAudioRestoredAt: "2026-09-22T10:06:00Z",
        systemAudioLossCount: 2,
    )
    #expect(try roundTrip(.capture(meta)) == .capture(meta))

    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])
    #expect(object["system_audio_lost_at"] as? String == "2026-09-22T10:05:00Z")
    #expect(object["system_audio_restored_at"] as? String == "2026-09-22T10:06:00Z")
    #expect(object["system_audio_loss_count"] as? Int == 2)
}

@Test func captureMetaWriteErrorAndRingCountsRoundTripInSnakeCase() throws {
    let meta = CaptureMeta(
        writeError: "diskFull",
        systemRingDroppedChunks: 1,
        systemRingTruncatedChunks: 2,
        micRingDroppedChunks: 3,
        micRingTruncatedChunks: 4,
    )
    #expect(try roundTrip(.capture(meta)) == .capture(meta))

    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])
    #expect(object["write_error"] as? String == "diskFull")
    #expect(object["system_ring_dropped_chunks"] as? Int == 1)
    #expect(object["system_ring_truncated_chunks"] as? Int == 2)
    #expect(object["mic_ring_dropped_chunks"] as? Int == 3)
    #expect(object["mic_ring_truncated_chunks"] as? Int == 4)
}

/// `stop` writes `mic_included`; recovery writes `reason`; an import writes
/// keys this type does not have.
@Test func onlyTheStopPayloadIsAStoppedCapture() throws {
    #expect(CaptureMeta(micIncluded: false, exactZeroSeconds: 0, tapRebuilds: 0).isStoppedCapture)
    #expect(!CaptureMeta(reason: "recovered_after_interruption").isStoppedCapture)
    #expect(!CaptureMeta(micIncluded: true, reason: "recovered_after_interruption").isStoppedCapture)
    let imported = try JSONDecoder().decode(CaptureMeta.self, from: Data(#"{"source_format":"wav","audio_duration_seconds":3}"#.utf8))
    #expect(!imported.isStoppedCapture)
}

/// An absent field is left out, not written as null, so a row carries only
/// what its event knew.
@Test func captureMetaOmitsFieldsItDoesNotHave() throws {
    let encoded = try String(bytes: JSONEncoder().encode(CaptureMeta(errorClass: "interrupted")), encoding: .utf8)
    #expect(encoded == #"{"error_class":"interrupted"}"#)
    #expect(try JSONDecoder().decode(CaptureMeta.self, from: Data("{}".utf8)) == CaptureMeta())
}

@Test func transcribeMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.transcribe(TranscribeMeta(
        modelID: "whisper-large-v3-turbo",
        audioDurationSeconds: 1827,
        transcriptChars: 23847,
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
        reviewSkipped: false,
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
        reviewSkipped: true,
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
        groundingMethod: "citations",
        fallbackTriggered: false,
        fallbackErrorClass: nil,
    ))
    #expect(try roundTrip(original) == original)
}

@Test func summarizeMetaWithFallbackRoundTripsLosslessly() throws {
    let original = StageMetadata.summarize(SummarizeMeta(
        modelID: "claude-opus-5",
        effortBudget: "medium",
        inputTokens: 4200,
        outputTokens: 900,
        thinkingTokens: 1200,
        costUSD: 0.32,
        quoteValidationDropCount: 0,
        groundingMethod: "substring",
        fallbackTriggered: true,
        fallbackErrorClass: "summarizer_citations_unavailable",
    ))
    #expect(try roundTrip(original) == original)
}

@Test func summarizeMetaEncodesFallbackFieldsUnderSnakeCaseKeys() throws {
    let meta = SummarizeMeta(
        modelID: "claude-opus-5",
        effortBudget: "medium",
        inputTokens: 1,
        outputTokens: 2,
        thinkingTokens: 3,
        costUSD: 0.1,
        quoteValidationDropCount: 0,
        groundingMethod: "substring",
        fallbackTriggered: true,
        fallbackErrorClass: "summarizer_rate_limited",
    )
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])

    #expect(object["fallback_triggered"] as? Bool == true)
    #expect(object["fallback_error_class"] as? String == "summarizer_rate_limited")
}

@Test func summarizeMetaEncodesTheCostCeilingUnderSnakeCaseKeys() throws {
    let meta = SummarizeMeta(
        modelID: "claude-opus-5",
        effortBudget: "medium",
        inputTokens: 1,
        outputTokens: 2,
        thinkingTokens: 3,
        costUSD: 0.5682,
        quoteValidationDropCount: 0,
        groundingMethod: "substring",
        fallbackTriggered: false,
        fallbackErrorClass: nil,
        costCeilingUSD: 0.5,
        costCeilingExceeded: true,
    )
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any])

    #expect(object["cost_ceiling_usd"] as? Double == 0.5)
    #expect(object["cost_ceiling_exceeded"] as? Bool == true)
    #expect(try JSONDecoder().decode(SummarizeMeta.self, from: JSONEncoder().encode(meta)) == meta)
}

@Test func summarizeMetaWrittenBeforeTheCostCeilingExistedStillDecodes() throws {
    let legacy = """
    {"model_id": "claude-opus-5", "effort_budget": "medium", "input_tokens": 1, "output_tokens": 2, \
    "thinking_tokens": 3, "cost_usd": 0.1, "quote_validation_drop_count": 0, \
    "grounding_method": "substring", "fallback_triggered": false}
    """

    let meta = try JSONDecoder().decode(SummarizeMeta.self, from: Data(legacy.utf8))

    #expect(meta.costCeilingUSD == nil)
    #expect(meta.costCeilingExceeded == nil)
}

@Test func persistMetaRoundTripsLosslessly() throws {
    let original = StageMetadata.persist(PersistMeta(
        vaultNotePath: "/Users/testuser/ObsidianVault/Meetings/2026-01-01 Tuesday Sync.md",
        frontmatterSchemaVersion: 1,
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
