/// Every way a diarization can fail, one case per stable failure class. No
/// case carries a payload: a path or a model's own message can therefore never
/// travel with the error into a log line or a `stage_events.error_message`,
/// and `String(describing:)` of a case is its own name.
public enum DiarizerError: Error, Sendable, Equatable {
    /// The model is not on disk, or what is on disk is incomplete.
    case modelUnavailable
    /// The model is on disk but could not be loaded.
    case modelLoadFailed
    /// The audio file is missing or cannot be read as audio.
    case audioUnreadable
    /// The model was loaded and the audio read, but diarization failed.
    case diarizationFailed
}
