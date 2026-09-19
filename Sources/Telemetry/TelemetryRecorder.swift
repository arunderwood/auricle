import Core
import State

/// The sole writer of `telemetry` rows (AR-PAT-4): every stage that
/// contributes rollup data — subprocess writers for count/cost/model
/// columns, the GUI Attribution sheet for applied/rejected columns
/// (AR-AI-5) — calls `record(meetingID:patch:)` rather than reaching
/// `StateStore`'s telemetry API directly.
///
/// The write-authority matrix is enforced by types: `record` accepts only a
/// `TelemetryPatch`, and each conforming type carries one writer's columns
/// and no others. The five reserved `transcription_suggestions_*` and
/// `transcription_review_*` columns have no patch type, so nothing can write
/// them until a writer exists.
public actor TelemetryRecorder {
    private let stateStore: StateStore

    public init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    /// The row is keyed by `meetingID`; a patch carries no identity of its own.
    public func record(meetingID: MeetingID, patch: some TelemetryPatch) async throws {
        try await stateStore.upsertTelemetry(patch.telemetry(for: meetingID))
    }
}
