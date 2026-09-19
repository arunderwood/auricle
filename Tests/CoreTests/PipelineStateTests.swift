import Core
import Testing

@Test func pipelineStateRawValuesMatchARPIPE2CanonicalSpellings() {
    let expected: [PipelineState: String] = [
        .recording: "recording",
        .captured: "captured",
        .transcribing: "transcribing",
        .reviewingDiarization: "reviewing_diarization",
        .awaitingAttribution: "awaiting_attribution",
        .attributing: "attributing",
        .summarizing: "summarizing",
        .persisting: "persisting",
        .published: "published",
        .awaitingVerification: "awaiting_verification",
        .verified: "verified",
        .retentionExpired: "retention_expired",
        .silent: "silent",
        .discarded: "discarded",
        .captureFailed: "capture_failed",
        .transcriptionFailed: "transcription_failed",
        .summarizationFailed: "summarization_failed",
        .persistFailed: "persist_failed",
        .publishedPartial: "published_partial",
    ]

    #expect(PipelineState.allCases.count == 19)
    #expect(expected.count == 19)
    for state in PipelineState.allCases {
        #expect(state.rawValue == expected[state])
    }
}
