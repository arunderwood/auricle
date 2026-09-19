import SummarizerInterface
import Testing

@Test func summarizerErrorIsFallbackEligibleMatchesIOMatrix() {
    #expect(SummarizerError.citationsUnavailable.isFallbackEligible)
    #expect(SummarizerError.malformedResponse.isFallbackEligible)
    #expect(SummarizerError.rateLimited.isFallbackEligible)
    #expect(SummarizerError.featureToggleDisabled.isFallbackEligible)

    #expect(!SummarizerError.networkTimeout.isFallbackEligible)
    #expect(!SummarizerError.authenticationFailed.isFallbackEligible)
    #expect(!SummarizerError.quotaExceeded.isFallbackEligible)
    #expect(!SummarizerError.responseTruncated.isFallbackEligible)
    #expect(!SummarizerError.apiKeyMissing.isFallbackEligible)
}
