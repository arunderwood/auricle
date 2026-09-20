import Core

/// Every way the review stage can end short of a full review, one case per
/// stable `errorClass`. No case carries a payload, so no path, model message
/// or transcript text reaches `stage_events`.
enum ReviewDiarizationStageError: ClassifiedStageError, Equatable, CaseIterable {
    /// The reviewer did not answer within the budget.
    case reviewerTimeout
    /// The reviewer threw.
    case reviewerFailed
    /// `transcript.json` or `diarization.json` is missing or undecodable.
    case inputsUnreadable
    /// The suggestions file could not be written.
    case suggestionsWriteFailed

    /// Spelled out per case so a rename cannot change a string that log
    /// queries and the stale-detection sweep's own class rely on.
    var errorClass: String {
        switch self {
        case .reviewerTimeout: "ai_reviewer_timeout"
        case .reviewerFailed: "ai_reviewer_failed"
        case .inputsUnreadable: "review_inputs_unreadable"
        case .suggestionsWriteFailed: "suggestions_write_failed"
        }
    }

    var errorMessage: String {
        String(describing: self)
    }

    /// A benign failure still advances the meeting with a stub in place. Only
    /// a failed write leaves nothing for attribution to read.
    var isBenign: Bool {
        self != .suggestionsWriteFailed
    }
}
