/// The `auricle-cli __internal-stage` subprocess protocol both
/// `SubprocessDispatcher` (sender) and `InternalStageWorker` (receiver)
/// speak (AR-PIPE-7). A single shared constant so the two call sites can
/// never silently drift apart — bump this when the argument vector or
/// exit-code contract between them changes, and both sides pick it up
/// automatically.
public enum WorkerProtocolVersion {
    public static let current = 1
}
