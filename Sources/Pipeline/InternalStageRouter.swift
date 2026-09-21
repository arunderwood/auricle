import AIReviewerInterface
import CalendarInterface
import Core
import Foundation
import Orchestrator
import ReviewDiarization
import State
import Summarize
import SummarizerInterface
import Telemetry
import Transcribe
import TranscriberInterface

/// What `auricle-cli __internal-stage` does once its command line has parsed:
/// validate it, open the state store, build the stage's dependencies and hand
/// the meeting to that stage's worker. It lives here rather than in the CLI
/// target because nothing under `App/` is reached by `swift test`, and the
/// wiring from the argument vector to each worker (which stage, which flags)
/// is what a regression would otherwise slip through.
///
/// Concrete strategies (WhisperKit, Claude, Google Calendar) are built by
/// `Environment`, so the CLI supplies them and a test supplies stubs.
public enum InternalStageRouter {
    public struct TranscribeDependencies {
        public let transcriber: any TranscriberStrategy
        public let config: TranscriberConfig
        public let diarize: TranscribeStage.DiarizationStep?
        public let ensureModel: @Sendable () async -> Void

        public init(
            transcriber: any TranscriberStrategy,
            config: TranscriberConfig,
            diarize: TranscribeStage.DiarizationStep?,
            ensureModel: @escaping @Sendable () async -> Void,
        ) {
            self.transcriber = transcriber
            self.config = config
            self.diarize = diarize
            self.ensureModel = ensureModel
        }
    }

    public struct ReviewDiarizationDependencies {
        public let reviewer: any DiarizationReviewerStrategy
        public let settings: ReviewDiarizationSettings

        public init(reviewer: any DiarizationReviewerStrategy, settings: ReviewDiarizationSettings) {
            self.reviewer = reviewer
            self.settings = settings
        }
    }

    public struct SummarizeDependencies {
        public let orchestrator: SummarizerOrchestrator
        public let glossary: Glossary
        public let config: SummarizerConfig
        public let calendarSource: (any CalendarSource)?

        public init(
            orchestrator: SummarizerOrchestrator,
            glossary: Glossary,
            config: SummarizerConfig,
            calendarSource: (any CalendarSource)?,
        ) {
            self.orchestrator = orchestrator
            self.glossary = glossary
            self.config = config
            self.calendarSource = calendarSource
        }
    }

    /// Each factory runs only for its own stage and only after the state store
    /// has opened, so a stage that cannot start builds nothing.
    public struct Environment {
        public let openStateStore: () throws -> StateStore
        public let transcribe: () -> TranscribeDependencies
        public let reviewDiarization: () -> ReviewDiarizationDependencies
        /// Receives the `--vault-path` value, which the dispatcher passes for the glossary.
        public let summarize: (_ vaultPath: String?) -> SummarizeDependencies

        public init(
            openStateStore: @escaping () throws -> StateStore,
            transcribe: @escaping () -> TranscribeDependencies,
            reviewDiarization: @escaping () -> ReviewDiarizationDependencies,
            summarize: @escaping (_ vaultPath: String?) -> SummarizeDependencies,
        ) {
            self.openStateStore = openStateStore
            self.transcribe = transcribe
            self.reviewDiarization = reviewDiarization
            self.summarize = summarize
        }
    }

    /// The status the process should end with. A message from argument
    /// validation is already a complete line; one from a worker, or from
    /// opening the store, carries the command-name prefix.
    public static func run(
        _ arguments: InternalStageArguments,
        environment: Environment,
        expectedProtocolVersion: Int = WorkerProtocolVersion.current,
    ) async -> WorkerExitStatus {
        switch arguments.decide(expectedProtocolVersion: expectedProtocolVersion) {
        case let .exit(status):
            return status

        case let .run(stage, meetingID):
            // Switching over `InternalStageKind` without a default is the
            // worker-coverage check: a stage `auricle run` dispatches here
            // does not compile until it has a case.
            guard let kind = InternalStageKind(stage: stage) else {
                return WorkerExitStatus(code: 2, message: "\(InternalStageArguments.commandName) is not yet implemented.")
            }
            let stateStore: StateStore
            do {
                stateStore = try environment.openStateStore()
            } catch {
                let cause = (error as? StateStoreError).map { String(describing: $0) } ?? String(describing: type(of: error))
                return prefixed(WorkerExitStatus(code: WorkerExitCode.stateError, message: "could not open the state store (\(cause))."))
            }
            let exit = switch kind {
            case .transcribe:
                await runTranscribe(meetingID: meetingID, stateStore: stateStore, environment: environment)
            case .reviewDiarization:
                await runReviewDiarization(meetingID: meetingID, stateStore: stateStore, environment: environment)
            case .summarize:
                await runSummarize(meetingID: meetingID, stateStore: stateStore, arguments: arguments, environment: environment)
            }
            return prefixed(exit)
        }
    }

    private static func prefixed(_ status: WorkerExitStatus) -> WorkerExitStatus {
        WorkerExitStatus(code: status.code, message: status.message.map { "\(InternalStageArguments.commandName): \($0)" })
    }

    private static func runTranscribe(meetingID: MeetingID, stateStore: StateStore, environment: Environment) async -> WorkerExitStatus {
        let dependencies = environment.transcribe()
        return await TranscribeWorker.run(
            meetingID: meetingID,
            stateStore: stateStore,
            stageRunner: StageRunner(stateStore: stateStore, stageEventLogger: StageEventLogger(stateStore: stateStore)),
            transcriber: dependencies.transcriber,
            config: dependencies.config,
            diarize: dependencies.diarize,
            ensureModel: dependencies.ensureModel,
        )
    }

    private static func runReviewDiarization(meetingID: MeetingID, stateStore: StateStore, environment: Environment) async -> WorkerExitStatus {
        let dependencies = environment.reviewDiarization()
        return await ReviewDiarizationWorker.run(
            meetingID: meetingID,
            stateStore: stateStore,
            stageRunner: StageRunner(stateStore: stateStore, stageEventLogger: StageEventLogger(stateStore: stateStore)),
            reviewer: dependencies.reviewer,
            settings: dependencies.settings,
        )
    }

    private static func runSummarize(
        meetingID: MeetingID,
        stateStore: StateStore,
        arguments: InternalStageArguments,
        environment: Environment,
    ) async -> WorkerExitStatus {
        let dependencies = environment.summarize(arguments.vaultPath)
        return await SummarizeWorker.run(
            meetingID: meetingID,
            stateStore: stateStore,
            orchestrator: dependencies.orchestrator,
            glossary: dependencies.glossary,
            config: dependencies.config,
            calendarSource: dependencies.calendarSource,
            publishAnyway: arguments.publishAnyway,
        )
    }
}
