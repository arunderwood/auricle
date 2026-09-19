import Core
import State

/// The GUI retention scheduler's column, backfilled at the snapshot mark.
public struct RetentionTelemetryPatch: TelemetryPatch, Equatable {
    public var audioRetentionStatusAtSnapshot: String?

    public init(audioRetentionStatusAtSnapshot: String? = nil) {
        self.audioRetentionStatusAtSnapshot = audioRetentionStatusAtSnapshot
    }

    public func telemetry(for meetingID: MeetingID) -> State.Telemetry {
        State.Telemetry(meetingID: meetingID.rawValue, audioRetentionStatusAtSnapshot: audioRetentionStatusAtSnapshot)
    }
}
