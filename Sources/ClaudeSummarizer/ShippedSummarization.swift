import Summarize

/// The summarization composition the app ships. The CLI's stage worker and
/// the eval harness both build their orchestrator here, so the harness cannot
/// pass on a composition nobody runs.
public enum ShippedSummarization {
    /// Substring only, no fallback: Decision 3.6's flip rule chose it (see
    /// Tests/fixtures/strategy-comparison-results.md). Citations returned no real
    /// citation objects on any transcript that had items, so a fallback to it
    /// would add a paid call that fails.
    ///
    /// Every strategy built here uses `httpClient`, so a test can observe all
    /// the calls the composition makes.
    public static func orchestrator(httpClient: AnthropicHTTPClient = AnthropicHTTPClient()) -> SummarizerOrchestrator {
        SummarizerOrchestrator(primary: ClaudeSubstringSummarizer(httpClient: httpClient))
    }
}
