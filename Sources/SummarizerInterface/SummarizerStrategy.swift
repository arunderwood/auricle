import Core

/// No `Meeting` parameter (AR-PAT-7 interface segregation): a strategy sees
/// only the transcript, glossary, and config it needs to produce grounded
/// output, never the full meeting record.
public protocol SummarizerStrategy: Sendable {
    func summarize(
        transcript: CanonicalTranscript,
        glossary: Glossary,
        config: SummarizerConfig,
    ) async throws -> SummaryWithGrounding
}
