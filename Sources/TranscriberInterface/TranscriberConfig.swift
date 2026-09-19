import Foundation

public struct TranscriberConfig: Sendable, Equatable {
    /// The identifier a transcript's `model_id` telemetry records, and the
    /// key a model store resolves to a model on disk.
    public static let defaultModelID = "whisper-large-v3-turbo"

    public let modelID: String
    /// Where the model already sits on disk. `nil` leaves the strategy to
    /// resolve `modelID` under its own model directory. A strategy never
    /// downloads a model to satisfy a transcription call.
    public let modelFolder: URL?

    public init(modelID: String = TranscriberConfig.defaultModelID, modelFolder: URL? = nil) {
        self.modelID = modelID
        self.modelFolder = modelFolder
    }
}
