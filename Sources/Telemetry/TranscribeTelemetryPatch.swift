import Core
import State

/// The `transcribe` subprocess's column.
public struct TranscribeTelemetryPatch: TelemetryPatch, Equatable {
    public var transcriptionWEREstimate: Double?

    public init(transcriptionWEREstimate: Double? = nil) {
        self.transcriptionWEREstimate = transcriptionWEREstimate
    }

    public func telemetry(for meetingID: MeetingID) -> State.Telemetry {
        State.Telemetry(meetingID: meetingID.rawValue, transcriptionWEREstimate: transcriptionWEREstimate)
    }
}
