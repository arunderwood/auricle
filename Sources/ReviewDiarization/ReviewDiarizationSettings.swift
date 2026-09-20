import Core

/// What the review stage reads from `~/.auricle/config.toml`, plus the one
/// budget that is not user-editable.
public struct ReviewDiarizationSettings: Sendable, Equatable {
    /// Matches the `reviewingDiarization` stale-detection budget in
    /// `StageRunner`: past it the sweep would move the meeting on anyway.
    public static let defaultTimeoutSeconds: Double = 90

    public let enabled: Bool
    public let modelID: String
    public let timeoutSeconds: Double

    public init(
        enabled: Bool = false,
        modelID: String = Config.DiarizationReview.defaultModel,
        timeoutSeconds: Double = ReviewDiarizationSettings.defaultTimeoutSeconds,
    ) {
        self.enabled = enabled
        self.modelID = modelID
        self.timeoutSeconds = timeoutSeconds
    }

    public init(config: Config) {
        self.init(enabled: config.diarizationReview.enabled, modelID: config.diarizationReview.model)
    }

    /// An unreadable config means flag off, reporting why to `onFailure`: the
    /// review is a paid extra, and a config typo must not start spending.
    public static func loading(config load: () throws -> Config, onFailure: (any Error) -> Void = { _ in }) -> ReviewDiarizationSettings {
        do {
            return try ReviewDiarizationSettings(config: load())
        } catch {
            onFailure(error)
            return ReviewDiarizationSettings()
        }
    }
}
