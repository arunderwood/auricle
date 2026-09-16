import Core
import State

/// The sole writer of `telemetry` rows (AR-PAT-4): every stage that
/// contributes rollup data — subprocess writers for count/cost/model
/// columns, the GUI Attribution sheet for applied/rejected columns
/// (AR-AI-5) — calls `record(meetingID:patch:)` rather than reaching
/// `StateStore`'s telemetry API directly. Which columns a given caller may
/// patch (AR-AI-5's write-authority matrix) is caller discipline, not
/// something this method validates — a patch touching a column another
/// writer owns is a code-review reject today, and a lint rule's job later,
/// the same as every other AR-PAT-4 primitive in this codebase.
///
/// `patch` is `State.Telemetry` — spelled out explicitly at every use site
/// in this file, since the unqualified name coincides with the `Telemetry`
/// *module* this type itself lives in.
public actor TelemetryRecorder {
    private let stateStore: StateStore

    public init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    /// `meetingID` is authoritative over whatever `patch.meetingID` happens
    /// to carry — callers build `patch` for its non-identity columns only,
    /// so this always stamps the row with the identity passed alongside it
    /// rather than trusting two separate copies of the same value to agree.
    public func record(meetingID: MeetingID, patch: State.Telemetry) async throws {
        var patch = patch
        patch.meetingID = meetingID.rawValue
        try await stateStore.upsertTelemetry(patch)
    }
}
