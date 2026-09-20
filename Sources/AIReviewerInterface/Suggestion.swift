/// What every AI-reviewer output shares, so the review UI and per-suggestion
/// telemetry can treat diarization, transcription and jargon suggestions alike.
public protocol Suggestion: Codable, Sendable {
    /// Stable across sheet reopens: Apply tracking and telemetry key on it.
    var suggestionId: String { get }
    /// Human-readable explanation shown in the expandable hint chip.
    var reasoning: String { get }
}
