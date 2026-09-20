import Core
import State

/// The `reviewing_diarization` subprocess's columns. The applied and rejected
/// counts are the attribute stage's, not this one's: the reviewer proposes
/// suggestions and the user accepts or rejects them later.
public struct ReviewDiarizationTelemetryPatch: TelemetryPatch, Equatable {
    public var diarizationSuggestionsCount: Int?
    public var diarizationReviewCostUSD: Double?
    public var diarizationReviewModel: String?

    public init(
        diarizationSuggestionsCount: Int? = nil,
        diarizationReviewCostUSD: Double? = nil,
        diarizationReviewModel: String? = nil,
    ) {
        self.diarizationSuggestionsCount = diarizationSuggestionsCount
        self.diarizationReviewCostUSD = diarizationReviewCostUSD
        self.diarizationReviewModel = diarizationReviewModel
    }

    public func telemetry(for meetingID: MeetingID) -> State.Telemetry {
        State.Telemetry(
            meetingID: meetingID.rawValue,
            diarizationSuggestionsCount: diarizationSuggestionsCount,
            diarizationReviewCostUSD: diarizationReviewCostUSD,
            diarizationReviewModel: diarizationReviewModel,
        )
    }
}
