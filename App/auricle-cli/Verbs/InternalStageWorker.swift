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
import Pipeline
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
        let status = await InternalStageRouter.run(arguments, environment: environment)
        if let message = status.message {
            writeStderr(message)
        }
        if status.code != WorkerExitCode.success {
            throw ExitCode(status.code)
        }
    }

    /// Builds the concrete strategies. `InternalStageRouter` owns when each
    /// factory runs, so `swift test` reaches the ordering and the exit codes.
    private var environment: InternalStageRouter.Environment {
        InternalStageRouter.Environment(
            openStateStore: { try StateStore.subprocess() },
            transcribe: { transcribeDependencies() },
            reviewDiarization: { reviewDiarizationDependencies() },
            summarize: { summarizeDependencies(vaultPath: $0) },
        )
    }

    private func transcribeDependencies() -> InternalStageRouter.TranscribeDependencies {
        let config = TranscriberConfig()
        let modelStore = WhisperKitModelStore()
        let diarizerConfig = diarizerConfig()
        let diarizerStore = SpeakerKitModelStore()
        let diarizer = WhisperKitDiarizer(store: diarizerStore)
        return InternalStageRouter.TranscribeDependencies(
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

    /// The reviewer is built even with the flag off: constructing it makes no
    /// network call and reads no key.
    private func reviewDiarizationDependencies() -> InternalStageRouter.ReviewDiarizationDependencies {
        let settings = ReviewDiarizationSettings.loading(
            config: { try Config.load() },
            onFailure: { writeStderr("__internal-stage: diarization review is off because the config could not be read (\(type(of: $0))).") },
        )
        return InternalStageRouter.ReviewDiarizationDependencies(reviewer: ClaudeDiarizationReviewer(), settings: settings)
    }

    private func summarizeDependencies(vaultPath: String?) -> InternalStageRouter.SummarizeDependencies {
        InternalStageRouter.SummarizeDependencies(
            orchestrator: ShippedSummarization.orchestrator(),
            glossary: vaultGlossary(vaultPath: vaultPath),
            config: SummarizerConfig(),
            calendarSource: calendarSource(),
            selfWikilink: (try? Config.load())?.selfWikilink,
        )
    }

    /// Empty when no vault path was given or the vault cannot be read: a
    /// vocabulary is an aid to the summary, never a reason to withhold it. The
    /// one line written names the failure's type only, because a path is the
    /// user's own and does not belong in a log.
    private func vaultGlossary(vaultPath: String?) -> Glossary {
        guard let vaultPath else { return Glossary() }
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
