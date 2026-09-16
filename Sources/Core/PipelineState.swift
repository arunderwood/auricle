/// Canonical pipeline state names (AR-PIPE-2), persisted verbatim as
/// `meetings.state` strings. `StateStore` and `Meeting` keep `state` as a
/// raw `String` (Story 1.4's design); this typed enum exists at the
/// `Orchestrator`/call-boundary layer so stage code works with a closed set
/// of cases instead of comparing string literals, converting via `.rawValue`
/// wherever it crosses into `StateStore`.
public enum PipelineState: String, Sendable, Codable, CaseIterable {
    case recording
    case captured
    case transcribing
    case reviewingDiarization = "reviewing_diarization"
    case awaitingAttribution = "awaiting_attribution"
    case attributing
    case summarizing
    case published
    case awaitingVerification = "awaiting_verification"
    case verified
    case retentionExpired = "retention_expired"
    case silent
    case discarded
    case captureFailed = "capture_failed"
    case transcriptionFailed = "transcription_failed"
    case summarizationFailed = "summarization_failed"
    case persistFailed = "persist_failed"
    case publishedPartial = "published_partial"
}
