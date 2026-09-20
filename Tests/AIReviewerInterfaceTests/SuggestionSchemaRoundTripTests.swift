@testable import AIReviewerInterface
import Core
import DiarizerInterface
import Foundation
import Testing

private func keys(of value: some Encodable) throws -> Set<String> {
    let data = try JSONEncoder().encode(value)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return Set(json.keys)
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private let cost = AIReviewerCost(inputTokens: 1200, outputTokens: 90, costUSD: 0.03, modelID: "claude-haiku-4-5")

private let diarizationSuggestion = DiarizationSuggestion(
    suggestionId: "diar-87",
    reasoning: "Two voices share one label.",
    kind: .underSegmentation,
    segmentId: "87",
    proposedSplits: [
        .init(start: 4.15, end: 4.32, speakerLabel: "Speaker_1"),
        .init(start: 4.32, end: 4.40, speakerLabel: "Speaker_2"),
    ],
)

private let transcriptionSuggestion = TranscriptionSuggestion(
    suggestionId: "tr-1",
    reasoning: "Homophone.",
    charRange: ByteRange(start: 10, end: 14),
    proposedReplacement: "their",
)

private let twoSegmentDiarization = DiarizationArtifact(segments: [
    DiarizedSegment(
        id: "seg_1", speakerLabel: "Speaker_1", startSeconds: 0, endSeconds: 2,
        utteranceIndex: DiarizedUtteranceRange(first: 0, last: 0),
        voiceProfile: DiarizedVoiceProfile(overlapRatio: 0),
    ),
    DiarizedSegment(
        id: "seg_2", speakerLabel: "Speaker_2", startSeconds: 2, endSeconds: 4,
        utteranceIndex: nil, voiceProfile: DiarizedVoiceProfile(overlapRatio: 0.1),
    ),
])

@Test func diarizationSuggestionRoundTripsThroughSnakeCaseJSON() throws {
    #expect(try keys(of: diarizationSuggestion) == ["suggestion_id", "reasoning", "kind", "segment_id", "proposed_splits"])
    #expect(try roundTrip(diarizationSuggestion) == diarizationSuggestion)

    let data = try JSONEncoder().encode(diarizationSuggestion)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["kind"] as? String == "under_segmentation")
    let splits = try #require(json["proposed_splits"] as? [[String: Any]])
    #expect(try Set(#require(splits.first).keys) == ["start", "end", "speaker_label"])
}

@Test func overSegmentationKindRoundTrips() throws {
    let merge = DiarizationSuggestion(
        suggestionId: "diar-9", reasoning: "One voice, two labels.",
        kind: .overSegmentation, segmentId: "9", proposedSplits: [],
    )
    #expect(try roundTrip(merge) == merge)
}

@Test func transcriptionSuggestionRoundTripsThroughSnakeCaseJSON() throws {
    #expect(try keys(of: transcriptionSuggestion) == ["suggestion_id", "reasoning", "char_range", "proposed_replacement"])
    #expect(try roundTrip(transcriptionSuggestion) == transcriptionSuggestion)
}

@Test func jargonCorrectionRoundTripsAsASuggestion() throws {
    let correction = JargonCorrection(
        suggestionId: "jargon-3-11", reasoning: "Glossary term.",
        charRange: ByteRange(start: 3, end: 11), originalSpan: "mesh core", correctedSpan: "meshcore",
    )
    let suggestion: any Suggestion = correction
    #expect(suggestion.suggestionId == "jargon-3-11")
    #expect(suggestion.reasoning == "Glossary term.")
    #expect(try roundTrip(correction) == correction)
}

@Test func costRoundTripsThroughSnakeCaseJSON() throws {
    #expect(try keys(of: cost) == ["input_tokens", "output_tokens", "cost_usd", "model_id"])
    #expect(try roundTrip(cost) == cost)
}

@Test func resultCarriesSchemaVersionOneAndRoundTrips() throws {
    let result = AIReviewerResult(suggestions: [diarizationSuggestion], cost: cost, reviewedSegmentCount: 80)
    #expect(result.schemaVersion == 1)
    #expect(try keys(of: result) == ["schema_version", "suggestions", "cost", "reviewed_segment_count"])
    #expect(try roundTrip(result) == result)

    let transcription = AIReviewerResult(suggestions: [transcriptionSuggestion], cost: cost, reviewedSegmentCount: 5)
    #expect(try roundTrip(transcription) == transcription)
}

@Test func anEmptyResultRoundTrips() throws {
    let empty = AIReviewerResult<DiarizationSuggestion>(
        suggestions: [],
        cost: AIReviewerCost(inputTokens: 0, outputTokens: 0, costUSD: 0, modelID: "flag_off"),
        reviewedSegmentCount: 0,
    )
    #expect(try roundTrip(empty) == empty)
}

@Test func audioFingerprintCarriesSchemaVersionOneAndRoundTrips() throws {
    let fingerprint = AudioFingerprint(audioSHA256: "ab12", durationSeconds: 1800.5)
    #expect(fingerprint.schemaVersion == 1)
    #expect(try keys(of: fingerprint) == ["schema_version", "audio_sha256", "duration_seconds"])
    #expect(try roundTrip(fingerprint) == fingerprint)
}

@Test func aResultMissingARequiredKeyFailsToDecode() {
    let json = Data(#"{"schema_version":1,"suggestions":[],"reviewed_segment_count":0}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AIReviewerResult<DiarizationSuggestion>.self, from: json)
    }
}

@Test func reviewInputsRoundTripAndAMockReviewerConforms() async throws {
    struct MockDiarizationReviewer: DiarizationReviewerStrategy {
        func review(
            input: DiarizationReviewInput,
            config: AIReviewerConfig,
        ) async throws -> AIReviewerResult<DiarizationSuggestion> {
            AIReviewerResult(
                suggestions: [],
                cost: AIReviewerCost(inputTokens: 0, outputTokens: 0, costUSD: 0, modelID: config.modelID),
                reviewedSegmentCount: input.diarization.segments.count,
            )
        }
    }
    struct MockTranscriptionReviewer: TranscriptionReviewerStrategy {
        func review(
            input: TranscriptionReviewInput,
            config: AIReviewerConfig,
        ) async throws -> AIReviewerResult<TranscriptionSuggestion> {
            AIReviewerResult(
                suggestions: [],
                cost: AIReviewerCost(inputTokens: 0, outputTokens: 0, costUSD: 0, modelID: config.modelID),
                reviewedSegmentCount: input.transcript.utteranceCount,
            )
        }
    }

    let transcript = CanonicalTranscript(text: "Speaker_1: hi", utterances: [
        .init(speakerLabel: "Speaker_1", start: 0, end: 13),
    ])
    let diarizationInput = DiarizationReviewInput(transcript: transcript, diarization: twoSegmentDiarization)
    let decoded = try JSONDecoder().decode(
        DiarizationReviewInput.self,
        from: JSONEncoder().encode(diarizationInput),
    )
    #expect(decoded == diarizationInput)
    #expect(decoded.transcript == transcript)
    #expect(try keys(of: diarizationInput) == ["transcript", "diarization"])

    let config = AIReviewerConfig(modelID: "claude-haiku-4-5")
    let diarizationResult = try await MockDiarizationReviewer().review(input: decoded, config: config)
    #expect(diarizationResult.reviewedSegmentCount == 2)
    #expect(diarizationResult.cost.modelID == "claude-haiku-4-5")

    let transcriptionInput = TranscriptionReviewInput(
        transcript: transcript, audio: AudioFingerprint(audioSHA256: "ab", durationSeconds: 1),
    )
    #expect(try keys(of: transcriptionInput) == ["transcript", "audio"])
    let transcriptionResult = try await MockTranscriptionReviewer().review(input: transcriptionInput, config: config)
    #expect(transcriptionResult.reviewedSegmentCount == 1)
}
