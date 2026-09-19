/// The successor table `StageRunner.run` checks an outcome against
/// (architecture.md Decision 1.2). Keyed by `(stage, activeState)`, the pair
/// `run` receives, so a stage run under another stage's active state has no
/// entry and is refused.
///
/// A stage with no entry cannot use `run` until its story adds one.
public enum PipelineTransitions {
    /// The states a run of `stage` under `activeState` may leave the meeting
    /// in, or `nil` when the pair has no entry.
    ///
    /// Transcribe completes into its own active state (no state sits between
    /// transcribe, diarize and review), so its active state is one of its own
    /// targets. Summarize completes into `persisting`, which persist runs under.
    public static func allowedTargets(stage: PipelineStage, activeState: PipelineState) -> Set<PipelineState>? {
        switch (stage, activeState) {
        case (.transcribe, .transcribing):
            [.transcribing, .reviewingDiarization, .transcriptionFailed]
        case (.reviewDiarization, .reviewingDiarization):
            // A reviewer that times out is a benign passthrough, not a
            // failure state, so the meeting still advances.
            [.awaitingAttribution]
        case (.summarize, .summarizing):
            [.persisting, .summarizationFailed]
        case (.persist, .persisting):
            [.published, .persistFailed]
        case (.notify, .published):
            // A notification failure is not a pipeline failure.
            [.awaitingVerification]
        default:
            nil
        }
    }
}
