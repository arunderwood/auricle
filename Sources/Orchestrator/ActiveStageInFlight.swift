import Core

/// The stage each of the 4 budgeted active states is waiting on: shared by
/// `StageRunner`'s stale-detection sweep (which stage's `stage_events` row
/// to record) and `CrashRecovery` (which stage a stuck meeting might be
/// re-dispatched into). `published` maps to `notify`, which runs in-process
/// per AR-PIPE-1 — this table only answers "which stage," not "is it a
/// subprocess"; a caller that only re-dispatches subprocess stages (like
/// `CrashRecovery`) filters that case out itself.
enum ActiveStageInFlight {
    static func stage(for activeState: PipelineState) -> PipelineStage? {
        switch activeState {
        case .transcribing: .transcribe
        case .reviewingDiarization: .reviewDiarization
        case .summarizing: .summarize
        case .published: .notify
        default: nil
        }
    }
}
