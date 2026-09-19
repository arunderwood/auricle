import SummarizerInterface

/// Every way `SummarizeStage` itself can fail, one case per stable
/// `errorClass`. No case carries a payload: the text of a transcript, a quote
/// or a foreign error can therefore never reach `stage_events.error_message`
/// or `metadata_json`, and `String(describing:)` of a case is its own name.
enum SummarizeStageError: Error, Equatable {
    /// `transcript.json` is absent or cannot be read.
    case transcriptMissing
    /// `transcript.json` is present but is not a `CanonicalTranscript`.
    case transcriptUndecodable
    /// `attribution.json` is present but its `speakers` object cannot be read.
    case attributionUndecodable
    /// The meeting row has no `capture_started_at`, or it is not an ISO8601
    /// timestamp, so the unenriched title has nothing to be built from.
    case captureStartedAtMissing
    /// A prompt file the summarizer strategies build their prompts from cannot
    /// be resolved, so the stage stops before the call that would spend money.
    case promptSetUnavailable
    /// A grounded item's pointer does not name a slice of the transcript.
    case quoteExtractionFailed
    /// An utterance's range does not name a slice of the transcript.
    case segmentExtractionFailed
    /// `summary.json` could not be written.
    case summaryWriteFailed

    var errorClass: String {
        switch self {
        case .transcriptMissing: "transcript_missing"
        case .transcriptUndecodable: "transcript_undecodable"
        case .attributionUndecodable: "attribution_undecodable"
        case .captureStartedAtMissing: "capture_started_at_missing"
        case .promptSetUnavailable: "prompt_set_unavailable"
        case .quoteExtractionFailed: "quote_extraction_failed"
        case .segmentExtractionFailed: "segment_extraction_failed"
        case .summaryWriteFailed: "summary_write_failed"
        }
    }
}

extension SummarizerError {
    /// The `errorClass` for a summarization failure, also recorded as
    /// `fallback_error_class` when the fallback strategy answered. Spelled
    /// out per case rather than derived from the case name, so a rename in
    /// `SummarizerError` cannot silently change a string that log queries
    /// and telemetry rely on.
    var stageErrorClass: String {
        switch self {
        case .citationsUnavailable: "summarizer_citations_unavailable"
        case .malformedResponse: "summarizer_malformed_response"
        case .rateLimited: "summarizer_rate_limited"
        case .featureToggleDisabled: "summarizer_feature_toggle_disabled"
        case .networkTimeout: "summarizer_network_timeout"
        case .authenticationFailed: "summarizer_authentication_failed"
        case .quotaExceeded: "summarizer_quota_exceeded"
        }
    }
}
