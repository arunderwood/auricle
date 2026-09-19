import Core
import SummarizerInterface

/// Decides whether a failed primary summarization call should retry via a
/// fallback strategy (Decision 3.3): neither `SummarizerStrategy`
/// implementation knows the other exists (AR-PAT-7), so this actor is the
/// one place that decision gets made. DI'd with both strategies from the
/// composition root (AR-PAT-5) — it never constructs a concrete strategy
/// itself, so which strategy is primary vs. fallback is a wiring decision,
/// not something this type hard-codes.
public actor SummarizerOrchestrator {
    /// What `summarize(transcript:glossary:config:)` returns on success,
    /// whichever strategy produced it. `fallbackTriggered`/`primaryError`
    /// are bookkeeping for a future caller (Story 3.7) to write into
    /// telemetry — this actor never calls `TelemetryRecorder` itself, since
    /// it has no `meetingID` to key a write against.
    public struct Outcome: Sendable {
        public let summary: SummaryWithGrounding
        public let fallbackTriggered: Bool
        public let primaryError: SummarizerError?

        public init(summary: SummaryWithGrounding, fallbackTriggered: Bool, primaryError: SummarizerError?) {
            self.summary = summary
            self.fallbackTriggered = fallbackTriggered
            self.primaryError = primaryError
        }
    }

    private let primary: SummarizerStrategy
    private let fallback: SummarizerStrategy?

    /// - Parameter fallback: `nil` when a second strategy would only add a
    ///   paid call that cannot succeed where the first did not; a
    ///   fallback-eligible primary error then propagates unchanged.
    public init(primary: SummarizerStrategy, fallback: SummarizerStrategy? = nil) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Calls `primary` once. A thrown `SummarizerError` whose
    /// `isFallbackEligible` is `true` triggers exactly one `fallback` call
    /// when one is configured (and rethrows unchanged when none is),
    /// passing `config` through unchanged. Any other error (a different `Error` type, or a
    /// `SummarizerError` with `isFallbackEligible == false`) propagates
    /// out of the `catch` below unmatched, which Swift rethrows to this
    /// function's own caller unchanged. A fallback failure is likewise
    /// never caught here, so it also rethrows unchanged — there is no
    /// second fallback attempt.
    public func summarize(
        transcript: CanonicalTranscript,
        glossary: Glossary,
        config: SummarizerConfig,
    ) async throws -> Outcome {
        do {
            let result = try await primary.summarize(transcript: transcript, glossary: glossary, config: config)
            return Outcome(summary: result, fallbackTriggered: false, primaryError: nil)
        } catch let primaryError as SummarizerError where primaryError.isFallbackEligible {
            guard let fallback else { throw primaryError }
            try Task.checkCancellation()
            let fallbackResult = try await fallback.summarize(transcript: transcript, glossary: glossary, config: config)
            return Outcome(summary: fallbackResult, fallbackTriggered: true, primaryError: primaryError)
        }
    }
}
