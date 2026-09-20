import Core

/// Every way the attribute stage refuses or fails, one case per stable
/// `errorClass`. The rejections happen before `StageRunner.run`, so they leave
/// the meeting's state and `stage_events` untouched.
public enum AttributionStageError: ClassifiedStageError, Equatable {
    /// The meeting is not waiting for attribution.
    case wrongState(current: String)
    /// `diarization.json` is missing or undecodable.
    case diarizationUnreadable
    /// An `attribution.json` exists but cannot be decoded.
    case attributionUnreadable
    /// Batch mode, with no `--speakers` and no speakers map to reuse.
    case noSpeakerMapping
    /// `--speakers` was refused.
    case invalidSpeakers(SpeakersFlagError)
    /// `attribution.json` could not be written.
    case attributionWriteFailed

    /// Spelled out per case so a rename cannot change a string that log
    /// queries rely on.
    public var errorClass: String {
        switch self {
        case .wrongState: "attribution_wrong_state"
        case .diarizationUnreadable: "attribution_diarization_unreadable"
        case .attributionUnreadable: "attribution_file_unreadable"
        case .noSpeakerMapping: "attribution_no_speaker_mapping"
        case .invalidSpeakers: "attribution_invalid_speakers"
        case .attributionWriteFailed: "attribution_write_failed"
        }
    }

    public var errorMessage: String {
        switch self {
        case .invalidSpeakers: "invalidSpeakers"
        default: String(describing: self)
        }
    }

    /// The line the CLI shows.
    public var userMessage: String {
        switch self {
        case let .wrongState(current): "the meeting is in state \(current), not awaiting_attribution."
        case .diarizationUnreadable: "the meeting has no readable diarization.json."
        case .attributionUnreadable: "the existing attribution.json cannot be read."
        case .noSpeakerMapping: "no speaker mapping; run with --interactive or pass --speakers"
        case let .invalidSpeakers(error): error.message
        case .attributionWriteFailed: "could not write attribution.json."
        }
    }
}
