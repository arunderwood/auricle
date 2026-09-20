import Core
import State

/// The columns of one `telemetry` row that a single writer owns (architecture
/// write-authority matrix, AR-AI-5). One conforming type per writer: a type
/// carries only its own writer's columns and no identity, so a writer cannot
/// name another writer's column, and the recorder stamps the row's id itself.
///
/// A `nil` property leaves its column as any earlier write left it; it never
/// clears one.
public protocol TelemetryPatch: Sendable {
    /// The full record with only this writer's non-`nil` columns set. Spelled
    /// `State.Telemetry` because the unqualified name is also this module's.
    func telemetry(for meetingID: MeetingID) -> State.Telemetry
}
