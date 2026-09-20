import Core
import State

/// The `summarize` subprocess's columns.
public struct SummarizeTelemetryPatch: TelemetryPatch, Equatable {
    public var quoteValidationDropCount: Int?
    public var summarizationPath: String?
    public var summarizationModel: String?
    public var summarizationEffortBudget: String?
    public var costUSD: Double?
    public var summarizationPromptSetHash: String?
    public var groundingMethod: String?

    public init(
        quoteValidationDropCount: Int? = nil,
        summarizationPath: String? = nil,
        summarizationModel: String? = nil,
        summarizationEffortBudget: String? = nil,
        costUSD: Double? = nil,
        summarizationPromptSetHash: String? = nil,
        groundingMethod: String? = nil,
    ) {
        self.quoteValidationDropCount = quoteValidationDropCount
        self.summarizationPath = summarizationPath
        self.summarizationModel = summarizationModel
        self.summarizationEffortBudget = summarizationEffortBudget
        self.costUSD = costUSD
        self.summarizationPromptSetHash = summarizationPromptSetHash
        self.groundingMethod = groundingMethod
    }

    public func telemetry(for meetingID: MeetingID) -> State.Telemetry {
        State.Telemetry(
            meetingID: meetingID.rawValue,
            quoteValidationDropCount: quoteValidationDropCount,
            summarizationPath: summarizationPath,
            summarizationModel: summarizationModel,
            summarizationEffortBudget: summarizationEffortBudget,
            costUSD: costUSD,
            groundingMethod: groundingMethod,
            summarizationPromptSetHash: summarizationPromptSetHash,
        )
    }
}
