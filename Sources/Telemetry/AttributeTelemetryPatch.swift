import Core
import State

/// The GUI `attribute` stage's columns: how attribution finished, and what the
/// user did with the reviewer's suggestions.
public struct AttributeTelemetryPatch: TelemetryPatch, Equatable {
    public var attributionCompletionPath: String?
    public var diarizationSuggestionsAppliedCount: Int?
    public var diarizationSuggestionsRejectedCount: Int?

    public init(
        attributionCompletionPath: String? = nil,
        diarizationSuggestionsAppliedCount: Int? = nil,
        diarizationSuggestionsRejectedCount: Int? = nil,
    ) {
        self.attributionCompletionPath = attributionCompletionPath
        self.diarizationSuggestionsAppliedCount = diarizationSuggestionsAppliedCount
        self.diarizationSuggestionsRejectedCount = diarizationSuggestionsRejectedCount
    }

    public func telemetry(for meetingID: MeetingID) -> State.Telemetry {
        State.Telemetry(
            meetingID: meetingID.rawValue,
            attributionCompletionPath: attributionCompletionPath,
            diarizationSuggestionsAppliedCount: diarizationSuggestionsAppliedCount,
            diarizationSuggestionsRejectedCount: diarizationSuggestionsRejectedCount,
        )
    }
}
