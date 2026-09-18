public enum SummarizerError: Error, Sendable {
    /// Anthropic returned no Citations data when Citations was requested.
    case citationsUnavailable
    /// The Citations response shape didn't validate.
    case malformedResponse
    /// Throughput limit hit.
    case rateLimited
    /// Anthropic disabled Citations on this model (defensive against future API changes).
    case featureToggleDisabled
    /// The HTTP request to Anthropic timed out.
    case networkTimeout
    /// The Anthropic API key was invalid or rejected.
    case authenticationFailed
    /// The account's Anthropic usage quota or billing limit was exceeded.
    case quotaExceeded

    /// `SummarizerOrchestrator` (Decision 3.3) falls back from Citations to
    /// substring only for these cases; network/auth/quota errors are
    /// re-thrown untouched since a fallback call would fail the same way.
    public var isFallbackEligible: Bool {
        switch self {
        case .citationsUnavailable, .malformedResponse, .rateLimited, .featureToggleDisabled:
            true
        case .networkTimeout, .authenticationFailed, .quotaExceeded:
            false
        }
    }
}
