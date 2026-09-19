import ArgumentParser
import ClaudeSummarizer
import Core
import Foundation
import Orchestrator
import State
import Summarize
import SummarizerInterface
import Telemetry
import VaultGlossary

// AR-PIPE-7: the GUI's and `CrashRecovery`'s subprocess-dispatch mechanism,
// not a user-facing verb — `shouldDisplay: false` keeps it out of `auricle
// help` and shell-completion scripts, and it is explicitly exempt from the
// NFR-I7 binding-contract guarantee every other verb carries.
struct InternalStageWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__internal-stage",
        shouldDisplay: false,
    )

    @Argument(help: "Pipeline stage to run.")
    var stage: String

    @Argument(help: "Meeting ID.")
    var id: String

    @Option(help: "Protocol version the dispatching process was built against.")
    var workerProtocolVersion: Int

    @Option(help: "Obsidian vault whose page names and wikilinks become the summarize stage's glossary.")
    var vaultPath: String?

    func run() async throws {
        switch InternalStageValidator.validate(stage: stage, workerProtocolVersion: workerProtocolVersion) {
        case .valid:
            switch PipelineStage(rawValue: stage) {
            case .summarize:
                try await runSummarize()
            default:
                try notYetImplemented("__internal-stage")
            }

        case let .unknownStage(stage):
            writeStderr("__internal-stage: unrecognized stage '\(stage)'.")
            throw ExitCode(1)

        case let .protocolVersionMismatch(mismatch):
            if let json = try? JSONEncoder().encode(mismatch),
               let jsonString = String(data: json, encoding: .utf8) {
                writeStderr(jsonString)
            } else {
                writeStderr(
                    "__internal-stage: worker protocol version mismatch "
                        + "(expected \(mismatch.expected), received \(mismatch.received)).",
                )
            }
            throw ExitCode(2)
        }
    }

    /// Wires `SummarizeStage`'s dependencies and hands it the meeting. The
    /// id is parsed before anything else so a malformed one never opens the
    /// state store; the stage's own outcome, not this function, decides the
    /// exit code.
    private func runSummarize() async throws {
        guard let meetingID = MeetingID(ulid: id) else {
            writeStderr("__internal-stage: '\(id)' is not a valid meeting ID.")
            throw ExitCode(1)
        }

        let stateStore: StateStore
        do {
            stateStore = try StateStore.subprocess()
        } catch {
            writeStderr("__internal-stage: could not open the state store (\(type(of: error))).")
            throw ExitCode(2)
        }

        // Substring only, no fallback: Decision 3.6's flip rule chose it (see
        // Tests/fixtures/smoke-test-results.md). Citations returned no real
        // citation objects on any transcript that had items, so a fallback to
        // it would add a paid call that fails.
        let orchestrator = SummarizerOrchestrator(primary: ClaudeSubstringSummarizer())

        let outcome: StageRunner.StageOutcome
        do {
            outcome = try await SummarizeStage.run(
                meetingID: meetingID,
                stateStore: stateStore,
                stageRunner: StageRunner(stateStore: stateStore, stageEventLogger: StageEventLogger(stateStore: stateStore)),
                telemetryRecorder: TelemetryRecorder(stateStore: stateStore),
                orchestrator: orchestrator,
                glossary: vaultGlossary(),
                config: SummarizerConfig(),
            )
        } catch StateStoreError.meetingNotFound {
            writeStderr("__internal-stage: no meeting with ID \(meetingID).")
            throw ExitCode(3)
        } catch {
            writeStderr("__internal-stage: summarize could not record its progress (\(type(of: error))).")
            throw ExitCode(2)
        }

        let exitCode = SummarizeStage.exitCode(for: outcome)
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    /// Empty when no vault path was given or the vault cannot be read: a
    /// vocabulary is an aid to the summary, never a reason to withhold it. The
    /// one line written names the failure's type only, because a path is the
    /// user's own and does not belong in a log.
    private func vaultGlossary() -> Glossary {
        guard let vaultPath else { return Glossary() }
        let url = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath, isDirectory: true)
        return VaultGlossaryBuilder(vaultPath: url).buildOrEmpty { error in
            writeStderr("__internal-stage: continuing without a vault glossary (\(type(of: error))).")
        }
    }
}
