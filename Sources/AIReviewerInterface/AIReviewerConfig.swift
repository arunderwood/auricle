/// Per-call reviewer settings. The model is named on every call so no
/// reviewer falls back to a provider default.
public struct AIReviewerConfig: Sendable, Equatable {
    public let modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }
}
