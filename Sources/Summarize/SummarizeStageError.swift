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
    /// `diarization.json` is present but is not a `DiarizationArtifact`.
    case diarizationUndecodable
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
        case .diarizationUndecodable: "diarization_undecodable"
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
        case .responseTruncated: "summarizer_response_truncated"
        case .apiKeyMissing: "summarizer_api_key_missing"
        }
    }

    /// What `stage_events.error_message` records: the case name for every
    /// failure a reader can diagnose from the class, and a sentence naming the
    /// fix for the one a first run hits before anything else has happened.
    /// Never a key, a path or a response body.
    var stageErrorMessage: String {
        switch self {
        case .apiKeyMissing:
            "No Anthropic API key in the Keychain. Store it under service \(Self.keychainServiceIdentifier), account api-key, then retry."
        default:
            String(describing: self)
        }
    }

    /// The Keychain service `KeychainAPIKey` reads. `Summarize` cannot import
    /// `ClaudeSummarizer`, so `AnthropicHTTPClientTests` pins this to
    /// `KeychainAPIKey.productionService`.
    static let keychainServiceIdentifier = "com.auricle.app.anthropic-api-key"
}
