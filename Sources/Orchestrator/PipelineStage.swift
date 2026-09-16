/// The 9 stage identifiers written to `stage_events.stage`. `reviewDiarization`
/// maps to `"review-diarization"` (hyphenated), matching AR-AI-3's
/// `__internal-stage review-diarization <id>` subcommand name rather than
/// the underscored convention `PipelineState` uses — the CLI verb and the
/// telemetry log share this one string, so the two can't diverge.
public enum PipelineStage: String, Sendable, Codable, CaseIterable {
    case capture
    case transcribe
    case reviewDiarization = "review-diarization"
    case attribute
    case summarize
    case persist
    case notify
    case verify
    case discard
}
