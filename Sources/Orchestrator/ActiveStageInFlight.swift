import Core

/// The stage each of the 5 budgeted active states is waiting on: shared by
/// `StageRunner`'s stale-detection sweep (which stage's `stage_events` row
/// to record) and `CrashRecovery` (which stage a stuck meeting might be
/// re-dispatched into). `persisting` and `published` map to `persist` and
/// `notify`, which run in-process per AR-PIPE-1 — this table only answers
/// "which stage," not "is it a subprocess"; a caller that only re-dispatches
/// subprocess stages (like `CrashRecovery`) filters those cases out itself.
enum ActiveStageInFlight {
    static func stage(for activeState: PipelineState) -> PipelineStage? {
        switch activeState {
        case .transcribing: .transcribe
        case .reviewingDiarization: .reviewDiarization
        case .summarizing: .summarize
        case .persisting: .persist
        case .published: .notify
        default: nil
        }
    }
}
