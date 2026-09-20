import Core
import DiarizerInterface

/// Every way the diarization step can fail, one case per stable `errorClass`.
/// No case carries a payload, so a path, a model's own message or transcript
/// text can never reach `stage_events.error_message`, and
/// `String(describing:)` of a case is its own name.
public enum DiarizeStageError: ClassifiedStageError, Equatable, CaseIterable {
    case modelUnavailable
    case modelLoadFailed
    case audioUnreadable
    case diarizationFailed
    /// `diarization.json` could not be written.
    case artifactWriteFailed
    /// A snippet or envelope file could not be produced or written.
    case snippetWriteFailed

    init(_ error: DiarizerError) {
        switch error {
        case .modelUnavailable: self = .modelUnavailable
        case .modelLoadFailed: self = .modelLoadFailed
        case .audioUnreadable: self = .audioUnreadable
        case .diarizationFailed: self = .diarizationFailed
        }
    }

    /// Spelled out per case, not derived from the case name, so a rename
    /// cannot silently change a string that log queries rely on.
    public var errorClass: String {
        switch self {
        case .modelUnavailable: DiarizeErrorClass.modelUnavailable
        case .modelLoadFailed: DiarizeErrorClass.modelLoadFailed
        case .audioUnreadable: DiarizeErrorClass.audioUnreadable
        case .diarizationFailed: DiarizeErrorClass.failed
        case .artifactWriteFailed: DiarizeErrorClass.artifactWriteFailed
        case .snippetWriteFailed: DiarizeErrorClass.snippetWriteFailed
        }
    }

    public var errorMessage: String {
        String(describing: self)
    }
}

/// Any error the step did not foresee. Only the type's name is kept: a
/// foreign error can embed a path or transcript text.
public struct DiarizeUnexpectedError: ClassifiedStageError, Equatable {
    public let typeName: String

    public var errorClass: String {
        DiarizeErrorClass.unexpected
    }

    public var errorMessage: String {
        typeName
    }
}
