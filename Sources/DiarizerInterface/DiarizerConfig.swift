import Core
import Foundation

public struct DiarizerConfig: Sendable, Equatable {
    /// What a `diarize` `model_id` records and what a model store resolves to
    /// a model on disk.
    public static let defaultModelID = "speakerkit-pyannote"

    /// A snippet shorter than this says too little to recognize a voice by,
    /// and one longer than this makes the attribution sheet slow to skim.
    public static let snippetDurationRange = 5 ... 10

    public let modelID: String
    /// Where the model already sits on disk. `nil` leaves the strategy to
    /// resolve `modelID` under its own model directory. A strategy never
    /// downloads a model to satisfy a diarization call.
    public let modelFolder: URL?
    /// Clamped into `snippetDurationRange`, so no caller can ask for a clip
    /// the sheet cannot use.
    public let snippetDurationSeconds: Int

    public init(
        modelID: String = DiarizerConfig.defaultModelID,
        modelFolder: URL? = nil,
        snippetDurationSeconds: Int = Config.Attribution.defaultSnippetDurationSeconds,
    ) {
        self.modelID = modelID
        self.modelFolder = modelFolder
        self.snippetDurationSeconds = min(max(snippetDurationSeconds, Self.snippetDurationRange.lowerBound), Self.snippetDurationRange.upperBound)
    }

    public init(config: Config) {
        self.init(snippetDurationSeconds: config.attribution.snippetDurationSeconds)
    }

    /// An unreadable config falls back to the defaults, reporting why to
    /// `onFailure`: a snippet is an aid to attribution, and a config typo
    /// must not stop diarization.
    public static func loading(config load: () throws -> Config, onFailure: (any Error) -> Void = { _ in }) -> DiarizerConfig {
        do {
            return try DiarizerConfig(config: load())
        } catch {
            onFailure(error)
            return DiarizerConfig()
        }
    }
}
