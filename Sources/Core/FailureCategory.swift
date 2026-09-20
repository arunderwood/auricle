/// How a pipeline state behaves when it is a failure or a known halt
/// (architecture.md Decision 4.1, AR-FAIL-1). The dispatcher consults it to
/// decide between retrying and surfacing, the GUI to pick a colour and an
/// affordance, and the CLI to map an exit code.
public enum FailureCategory: String, Sendable, Codable, CaseIterable {
    /// Likely to succeed on a retry: the cause is environmental.
    case transient
    /// Will not succeed without the user: the cause is structural.
    case permanent
    /// The pipeline is waiting on the user by design. Not a failure.
    case userActionable = "user_actionable"
    /// The pipeline finished correctly by finding nothing to do.
    case benignTerminal = "benign_terminal"
}

public extension PipelineState {
    /// Derived from the state alone and never stored (Decision 4.1), so it
    /// cannot disagree with `meetings.state`. `nil` for every state that is
    /// neither a failure nor a halt: the active `_ing` states, the happy-path
    /// hand-offs, and the user-initiated `discarded`.
    var failureCategory: FailureCategory? {
        switch self {
        case .summarizationFailed, .persistFailed:
            .transient
        case .captureFailed, .transcriptionFailed:
            .permanent
        case .awaitingAttribution, .awaitingVerification, .publishedPartial:
            .userActionable
        case .silent:
            .benignTerminal
        case .recording, .captured, .transcribing, .reviewingDiarization, .attributing,
             .summarizing, .persisting, .published, .verified, .retentionExpired, .discarded:
            nil
        }
    }

    /// Whether this is one of the four `*_failed` states. The stage runner
    /// logs a move into one at error level.
    var isFailed: Bool {
        switch self {
        case .captureFailed, .transcriptionFailed, .summarizationFailed, .persistFailed:
            true
        default:
            false
        }
    }
}
