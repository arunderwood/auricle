/// An error a stage step reports with a stable `error_class` and a message
/// that is safe to persist. It lets a stage that runs another module's step
/// record that step's failure without importing the module: the step throws
/// this, and the stage reads the two strings.
///
/// The message is a case name, a type name or a fixed sentence, never an
/// underlying error's own text, because `stage_events.error_message` is
/// persisted.
public protocol ClassifiedStageError: Error {
    var errorClass: String { get }
    var errorMessage: String { get }
}

/// The `error_class` strings of the diarization step. They live in `Core`
/// because two modules that must not import each other both need them: the
/// step that raises them and the transcribe stage that decides which are
/// worth a retry.
public enum DiarizeErrorClass {
    public static let modelUnavailable = "diarize_model_unavailable"
    public static let modelLoadFailed = "diarize_model_load_failed"
    public static let audioUnreadable = "diarize_audio_unreadable"
    public static let failed = "diarize_failed"
    public static let artifactWriteFailed = "diarization_write_failed"
    public static let snippetWriteFailed = "snippet_write_failed"
    public static let unexpected = "diarize_unexpected_error"

    /// The classes a fresh process might not repeat.
    public static let retryable: Set<String> = [modelUnavailable, modelLoadFailed, failed]
}
