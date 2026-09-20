import Core
import TranscriberInterface

/// Every way `TranscribeStage` itself can fail, one case per stable
/// `errorClass`. No case carries a payload: a path, a model's own message or
/// transcript text can therefore never reach `stage_events.error_message` or
/// `metadata_json`, and `String(describing:)` of a case is its own name.
enum TranscribeStageError: ClassifiedStageError, Equatable, CaseIterable {
    /// There is no `audio.wav` in the meeting's cache directory.
    case audioMissing
    /// `audio.wav` is present but cannot be opened as audio.
    case audioUnreadable
    /// The model is not on disk, or is incomplete.
    case modelUnavailable
    /// The model is on disk but could not be loaded.
    case modelLoadFailed
    /// The model was loaded and the audio opened, but decoding failed.
    case transcriptionFailed
    /// `transcript.json` could not be written.
    case transcriptWriteFailed

    init(_ error: TranscriberError) {
        switch error {
        case .modelUnavailable: self = .modelUnavailable
        case .modelLoadFailed: self = .modelLoadFailed
        case .audioUnreadable: self = .audioUnreadable
        case .transcriptionFailed: self = .transcriptionFailed
        }
    }

    /// Spelled out per case rather than derived from the case name, so a
    /// rename cannot silently change a string that log queries and telemetry
    /// rely on.
    var errorClass: String {
        switch self {
        case .audioMissing: "audio_missing"
        case .audioUnreadable: "audio_unreadable"
        case .modelUnavailable: "transcribe_model_unavailable"
        case .modelLoadFailed: "transcribe_model_load_failed"
        case .transcriptionFailed: "transcribe_failed"
        case .transcriptWriteFailed: "transcript_write_failed"
        }
    }

    /// True for the failures a fresh process might not repeat: the model
    /// could not be found or loaded, or decoding failed. A missing or
    /// unreadable audio file, a failed write and an unforeseen error would
    /// fail the same way again, so retrying them only delays the failure.
    var isRetryable: Bool {
        switch self {
        case .modelUnavailable, .modelLoadFailed, .transcriptionFailed: true
        case .audioMissing, .audioUnreadable, .transcriptWriteFailed: false
        }
    }

    var errorMessage: String {
        String(describing: self)
    }

    /// The diarization step runs inside this stage's worker, so its
    /// retryable classes belong to the set the exit code is read from.
    static let retryableErrorClasses = Set(allCases.filter(\.isRetryable).map(\.errorClass)).union(DiarizeErrorClass.retryable)
}
