import AIReviewerInterface
import ArgumentParser
import CalendarInterface
import ClaudeAIReviewers
import ClaudeSummarizer
import Core
import Diarize
import DiarizerInterface
import Foundation
import GoogleCalendarSource
import Orchestrator
import ReviewDiarization
import State
import Summarize
import SummarizerInterface
import Telemetry
import Transcribe
import TranscriberInterface
import VaultGlossary
import WhisperKitDiarizer
import WhisperKitTranscriber

// AR-PIPE-7: the GUI's and `CrashRecovery`'s subprocess-dispatch mechanism,
// not a user-facing verb — `shouldDisplay: false` keeps it out of `auricle
// help` and shell-completion scripts, and it is explicitly exempt from the
// NFR-I7 binding-contract guarantee every other verb carries.
//
// The command line is `InternalStageArguments`, the same type
// `SubprocessDispatcher` builds its argument vector from, and validating it is
// that type's job; this command only wires dependencies and turns an exit
// status into a process exit.
struct InternalStageWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: InternalStageArguments.commandName,
        shouldDisplay: false,
    )

    @OptionGroup var arguments: InternalStageArguments

    func run() async throws {
        switch arguments.decide() {
        case let .exit(status):
            try finish(status, prefixed: false)

        case let .run(stage, meetingID):
            switch stage {
            case .transcribe:
                try await runTranscribe(meetingID: meetingID)
            case .reviewDiarization:
                try await runReviewDiarization(meetingID: meetingID)
            case .summarize:
                try await runSummarize(meetingID: meetingID)
            default:
                try notYetImplemented(InternalStageArguments.commandName)
            }
        }
    }

    /// Writes the status's message, if any, and exits non-zero unless it is a
    /// success. A message from a worker gets the command-name prefix; the one
    /// from argument validation is already a complete line.
    private func finish(_ status: WorkerExitStatus, prefixed: Bool) throws {
        if let message = status.message {
            writeStderr(prefixed ? "\(InternalStageArguments.commandName): \(message)" : message)
        }
        if status.code != WorkerExitCode.success {
            throw ExitCode(status.code)
        }
    }

    /// Opens the state store the way every worker does. A typed store error
    /// names its case, and any other names its type only.
    private func openStateStore() throws -> StateStore {
        do {
            return try StateStore.subprocess()
        } catch {
            let cause = (error as? StateStoreError).map { String(describing: $0) } ?? String(describing: type(of: error))
            writeStderr("\(InternalStageArguments.commandName): could not open the state store (\(cause)).")
            throw ExitCode(WorkerExitCode.stateError)
        }
    }

    /// Builds the concrete transcriber and hands it to `TranscribeWorker`,
    /// which owns the ordering and the exit codes so `swift test` reaches
    /// them.
    private func runTranscribe(meetingID: MeetingID) async throws {
        let stateStore = try openStateStore()
        let config = TranscriberConfig()
        let modelStore = WhisperKitModelStore()
        let diarizerConfig = diarizerConfig()
        let diarizerStore = SpeakerKitModelStore()
        let diarizer = WhisperKitDiarizer(store: diarizerStore)
        let exit = await TranscribeWorker.run(
            meetingID: meetingID,
            stateStore: stateStore,
            stageRunner: StageRunner(stateStore: stateStore, stageEventLogger: StageEventLogger(stateStore: stateStore)),
            transcriber: WhisperKitTranscriber(store: modelStore),
            config: config,
            diarize: { input in
                try await DiarizeStage.run(
                    meetingID: input.meetingID,
                    transcript: input.transcript,
                    utteranceTimings: input.utteranceTimings,
                    audio: input.audio,
                    diarizer: diarizer,
                    config: diarizerConfig,
                )
            },
            ensureModel: {
                await Self.provisionModelIfMissing(modelStore, config: config)
                await Self.provisionDiarizerModelIfMissing(diarizerStore)
            },
        )
        try finish(exit, prefixed: true)
    }

    /// The one line written says a download is starting and, if it fails,
    /// names the failure's type only. A failed download is not fatal here: the
    /// stage runs anyway and records the missing model as its own failure.
    private static func provisionModelIfMissing(_ modelStore: WhisperKitModelStore, config: TranscriberConfig) async {
        guard !modelStore.isProvisioned(modelID: config.modelID) else { return }
        writeStderr("__internal-stage: downloading the transcription model (one time only).")
        do {
            try await modelStore.provision(modelID: config.modelID)
        } catch {
            writeStderr("__internal-stage: the transcription model could not be downloaded (\(type(of: error))).")
        }
    }

    private static func provisionDiarizerModelIfMissing(_ store: SpeakerKitModelStore) async {
        guard !store.isProvisioned else { return }
        writeStderr("__internal-stage: downloading the diarization model (one time only).")
        do {
            try await store.provision()
        } catch {
            writeStderr("__internal-stage: the diarization model could not be downloaded (\(type(of: error))).")
        }
    }

    /// Falls back to the default snippet length when the config cannot be
    /// read. The line written names the failure's type only.
    private func diarizerConfig() -> DiarizerConfig {
        DiarizerConfig.loading(
            config: { try Config.load() },
            onFailure: { writeStderr("__internal-stage: using the default snippet length (\(type(of: $0))).") },
        )
    }

    /// Builds the Claude reviewer and hands the meeting to
    /// `ReviewDiarizationWorker`. The reviewer is built even with the flag off:
    /// constructing it makes no network call and reads no key.
    private func runReviewDiarization(meetingID: MeetingID) async throws {
        let stateStore = try openStateStore()
        let settings = ReviewDiarizationSettings.loading(
            config: { try Config.load() },
            onFailure: { writeStderr("__internal-stage: diarization review is off because the config could not be read (\(type(of: $0))).") },
        )
        let exit = await ReviewDiarizationWorker.run(
            meetingID: meetingID,
            stateStore: stateStore,
            stageRunner: StageRunner(stateStore: stateStore, stageEventLogger: StageEventLogger(stateStore: stateStore)),
            reviewer: ClaudeDiarizationReviewer(),
            settings: settings,
        )
        try finish(exit, prefixed: true)
    }

    /// Wires `SummarizeStage`'s dependencies and hands the meeting to
    /// `SummarizeWorker`, which owns the mapping from the stage's result to an
    /// exit status.
    private func runSummarize(meetingID: MeetingID) async throws {
        let stateStore = try openStateStore()
        let exit = await SummarizeWorker.run(
            meetingID: meetingID,
            stateStore: stateStore,
            orchestrator: ShippedSummarization.orchestrator(),
            glossary: vaultGlossary(),
            config: SummarizerConfig(),
            calendarSource: calendarSource(),
        )
        try finish(exit, prefixed: true)
    }

    /// Empty when no vault path was given or the vault cannot be read: a
    /// vocabulary is an aid to the summary, never a reason to withhold it. The
    /// one line written names the failure's type only, because a path is the
    /// user's own and does not belong in a log.
    private func vaultGlossary() -> Glossary {
        guard let vaultPath = arguments.vaultPath else { return Glossary() }
        let url = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath, isDirectory: true)
        return VaultGlossaryBuilder(vaultPath: url).buildOrEmpty { error in
            writeStderr("__internal-stage: continuing without a vault glossary (\(type(of: error))).")
        }
    }

    /// `nil` when `~/.auricle/config.toml` names no Google client id or cannot
    /// be read: a calendar is an aid to the note, never a reason to withhold
    /// it, and the stage already treats a missing source as unenriched. The
    /// worker reads the config itself, unlike the vault path, because the
    /// client id is not something the dispatcher passes along. The line
    /// written names the failure's type only.
    private func calendarSource() -> (any CalendarSource)? {
        let config: Config
        do {
            config = try Config.load()
        } catch {
            writeStderr("__internal-stage: continuing without a calendar (\(type(of: error))).")
            return nil
        }
        return GoogleCalendarSource.headless(config.googleCalendar)
    }
}
