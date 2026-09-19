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
    /// The response stopped at the request's `max_tokens`, so its JSON body is
    /// cut off mid-value. Distinct from `malformedResponse`: the model was
    /// answering correctly and ran out of budget, which a retry under the
    /// same budget does not fix.
    case responseTruncated
    /// No Anthropic API key is stored in the Keychain.
    case apiKeyMissing

    /// `SummarizerOrchestrator` (Decision 3.3) falls back from Citations to
    /// substring only for these cases; network/auth/quota/key errors are
    /// re-thrown untouched since a fallback call would fail the same way. A
    /// truncated response is re-thrown too: the fallback is a second paid
    /// call over the same transcript under the same `max_tokens`.
    public var isFallbackEligible: Bool {
        switch self {
        case .citationsUnavailable, .malformedResponse, .rateLimited, .featureToggleDisabled:
            true
        case .networkTimeout, .authenticationFailed, .quotaExceeded, .responseTruncated, .apiKeyMissing:
            false
        }
    }
}
