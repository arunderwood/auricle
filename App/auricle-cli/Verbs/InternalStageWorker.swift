import ArgumentParser
import ClaudeSummarizer
import Core
import Foundation
import Orchestrator
import State
import Summarize
import SummarizerInterface
import Telemetry

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

        // Provisional: Citations as primary with substring as fallback is
        // Decision 3.6's stated MVP default, pending the Story 3.8 smoke-test
        // result that locks or flips it.
        let orchestrator = SummarizerOrchestrator(
            primary: ClaudeCitationsSummarizer(),
            fallback: ClaudeSubstringSummarizer(),
        )

        let outcome: StageRunner.StageOutcome
        do {
            outcome = try await SummarizeStage.run(
                meetingID: meetingID,
                stateStore: stateStore,
                stageRunner: StageRunner(stateStore: stateStore, stageEventLogger: StageEventLogger(stateStore: stateStore)),
                telemetryRecorder: TelemetryRecorder(stateStore: stateStore),
                orchestrator: orchestrator,
                // Empty: the vault glossary builder (Story 3.12) is what fills it.
                glossary: Glossary(),
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
}
