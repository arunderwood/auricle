import Core

/// The subprocess stages `InternalStageWorker` must have a case for. The
/// worker switches over this type without a default, so a stage added here
/// does not compile until the worker runs it.
public enum InternalStageKind: CaseIterable, Sendable {
    case transcribe
    case reviewDiarization
    case summarize

    public init?(stage: PipelineStage) {
        switch stage {
        case .transcribe: self = .transcribe
        case .reviewDiarization: self = .reviewDiarization
        case .summarize: self = .summarize
        case .capture, .attribute, .persist, .notify, .verify, .discard: return nil
        }
    }

    public var stage: PipelineStage {
        switch self {
        case .transcribe: .transcribe
        case .reviewDiarization: .reviewDiarization
        case .summarize: .summarize
        }
    }
}

/// The stages `auricle run` can drive, in pipeline order. Diarization runs
/// inside `transcribe`, which has no separate stage.
public enum RunStage: String, CaseIterable, Sendable, Comparable {
    case transcribe
    case reviewDiarization = "review-diarization"
    case attribute
    case summarize
    case persist
    case notify

    /// Where a stage runs (AR-PIPE-1). Exhaustive, so a new stage must say.
    public enum Execution: Sendable, Equatable {
        case subprocess(InternalStageKind)
        case inProcess
    }

    public var execution: Execution {
        switch self {
        case .transcribe: .subprocess(.transcribe)
        case .reviewDiarization: .subprocess(.reviewDiarization)
        case .summarize: .subprocess(.summarize)
        case .attribute, .persist, .notify: .inProcess
        }
    }

    public var pipelineStage: PipelineStage {
        switch self {
        case .transcribe: .transcribe
        case .reviewDiarization: .reviewDiarization
        case .attribute: .attribute
        case .summarize: .summarize
        case .persist: .persist
        case .notify: .notify
        }
    }

    /// The states this stage can begin from: the state the stage before it
    /// leaves, its own active or failed state, and the finished states a
    /// deliberate re-run starts from. `transcribe` is the one stage that
    /// starts anywhere, because it discards everything after it.
    ///
    /// Not a rule of the state machine: `StageRunner` runs a stage under
    /// whichever active state it is given. It is what stops `--from` and
    /// `--only` naming a stage the meeting has not reached.
    public var entryStates: Set<PipelineState> {
        switch self {
        case .transcribe:
            Set(PipelineState.allCases)
        case .reviewDiarization:
            [.transcribing, .reviewingDiarization, .awaitingAttribution]
        case .attribute:
            [.awaitingAttribution, .attributing, .awaitingVerification, .published, .publishedPartial]
        case .summarize:
            [.summarizing, .summarizationFailed, .persistFailed, .awaitingVerification, .published, .publishedPartial]
        case .persist:
            [.persisting, .persistFailed]
        case .notify:
            [.published, .publishedPartial]
        }
    }

    var entryStateList: String {
        entryStates.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    public static func < (lhs: RunStage, rhs: RunStage) -> Bool {
        lhs.order < rhs.order
    }
}

/// `RunArguments` as typed values.
public struct RunOptions: Sendable, Equatable {
    public var force: Bool
    public var from: RunStage?
    public var to: RunStage?
    public var only: RunStage?
    public var reattribute: Bool
    public var publishAnyway: Bool

    public init(
        force: Bool = false,
        from: RunStage? = nil,
        to: RunStage? = nil,
        only: RunStage? = nil,
        reattribute: Bool = false,
        publishAnyway: Bool = false,
    ) {
        self.force = force
        self.from = from
        self.to = to
        self.only = only
        self.reattribute = reattribute
        self.publishAnyway = publishAnyway
    }
}

/// Why a meeting cannot be run as asked. Every case exits 1.
public enum RunRefusal: Error, Equatable, Sendable {
    /// `verified`, `discarded`, `silent`, `recording`, `retention_expired`.
    case notRunnable(PipelineState)
    /// `capture_failed` or `transcription_failed`, without `--force`.
    case permanentFailure(PipelineState)
    /// `--reattribute` on a meeting that has not been published.
    case notPublished(PipelineState)
    /// `--to` names a stage before the one the run starts at.
    case toPrecedesStart(to: RunStage, start: RunStage)
    /// The stage the run starts at cannot begin from the meeting's state.
    case cannotStart(stage: RunStage, state: PipelineState)

    public var message: String {
        switch self {
        case let .notRunnable(state):
            "a meeting in state \(state.rawValue) cannot be run."
        case let .permanentFailure(state):
            "the meeting is in state \(state.rawValue). After investigating, re-run it with --force."
        case let .notPublished(state):
            "--reattribute needs a published meeting; this one is in state \(state.rawValue)."
        case let .toPrecedesStart(to, start):
            "--to \(to.rawValue) comes before \(start.rawValue), where this run starts."
        case let .cannotStart(stage, state):
            "\(stage.rawValue) cannot start from state \(state.rawValue); it starts from \(stage.entryStateList)."
        }
    }
}

/// What a run does, decided before anything runs: the stages to drive, in
/// order. Pure, so every flag and state combination is testable without a
/// database.
public struct RunPlan: Sendable, Equatable {
    /// Empty when there is nothing to run from the meeting's state.
    public let stages: [RunStage]
    public let publishAnyway: Bool

    public init(stages: [RunStage], publishAnyway: Bool) {
        self.stages = stages
        self.publishAnyway = publishAnyway
    }

    /// An explicit `--from` or `--only` beats the start the state implies.
    /// `--force` starts at `transcribe` and implies `--reattribute`.
    public static func make(options: RunOptions, state: PipelineState) -> Result<RunPlan, RunRefusal> {
        let start: RunStage?
        switch resolveStart(options: options, state: state) {
        case let .success(resolved): start = resolved
        case let .failure(refusal): return .failure(refusal)
        }

        let stages: [RunStage]
        if let only = options.only {
            stages = [only]
        } else if let start {
            if let to = options.to, to < start {
                return .failure(.toPrecedesStart(to: to, start: start))
            }
            let end = options.to ?? .notify
            stages = RunStage.allCases.filter { $0 >= start && $0 <= end }
        } else {
            stages = []
        }
        if let first = stages.first, !first.entryStates.contains(state) {
            return .failure(.cannotStart(stage: first, state: state))
        }
        return .success(RunPlan(stages: stages, publishAnyway: options.publishAnyway))
    }

    private static func resolveStart(options: RunOptions, state: PipelineState) -> Result<RunStage?, RunRefusal> {
        switch state {
        case .recording, .silent, .verified, .discarded, .retentionExpired:
            return .failure(.notRunnable(state))
        default:
            break
        }

        if state == .captureFailed || state == .transcriptionFailed, !options.force {
            return .failure(.permanentFailure(state))
        }
        if let only = options.only {
            return .success(only)
        }
        if let from = options.from {
            return .success(from)
        }
        if options.force {
            return .success(.transcribe)
        }

        let published: Set<PipelineState> = [.awaitingVerification, .published, .publishedPartial]
        if options.reattribute {
            guard published.contains(state) else { return .failure(.notPublished(state)) }
            return .success(.attribute)
        }
        return .success(startStage(for: state))
    }

    /// The stage that continues a meeting from where it stopped.
    /// `published_partial` resumes at `summarize`, the stage whose output it
    /// lacks. `awaiting_verification` has nothing left to run.
    private static func startStage(for state: PipelineState) -> RunStage? {
        switch state {
        case .captured, .transcribing, .captureFailed, .transcriptionFailed: .transcribe
        case .reviewingDiarization: .reviewDiarization
        case .awaitingAttribution, .attributing: .attribute
        case .summarizing, .summarizationFailed, .publishedPartial: .summarize
        case .persisting, .persistFailed: .persist
        case .published: .notify
        case .awaitingVerification, .recording, .silent, .verified, .discarded, .retentionExpired: nil
        }
    }
}
