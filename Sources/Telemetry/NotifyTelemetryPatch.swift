import Core
import State

/// The `notify` stage's timing columns.
public struct NotifyTelemetryPatch: TelemetryPatch, Equatable {
    public var timeToAttributionReadySeconds: Int?
    public var timeToVaultNoteSeconds: Int?

    public init(timeToAttributionReadySeconds: Int? = nil, timeToVaultNoteSeconds: Int? = nil) {
        self.timeToAttributionReadySeconds = timeToAttributionReadySeconds
        self.timeToVaultNoteSeconds = timeToVaultNoteSeconds
    }

    public func telemetry(for meetingID: MeetingID) -> State.Telemetry {
        State.Telemetry(
            meetingID: meetingID.rawValue,
            timeToAttributionReadySeconds: timeToAttributionReadySeconds,
            timeToVaultNoteSeconds: timeToVaultNoteSeconds,
        )
    }
}
