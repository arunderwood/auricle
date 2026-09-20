import ArgumentParser
import Attribute
import Core
import Foundation
import Orchestrator
import State
import Telemetry
import VaultGlossary

/// Every invocation is batch: `--speakers` names the speakers, and `--batch`
/// alone or no flag reuses the mapping already on disk. The logic lives in
/// `AttributionStage` so `swift test` reaches it; this verb only wires
/// dependencies.
struct AttributeVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attribute",
        abstract: "Attribute speakers for a meeting. Opens the GUI by default.",
    )

    @OptionGroup var arguments: AttributeArguments

    func run() async throws {
        guard let meetingID = MeetingID(ulid: arguments.id) else {
            throw failure("\(arguments.id) is not a full meeting id.")
        }
        let stateStore = try openStateStore()
        let status = await AttributionStage.execute(
            meetingID: meetingID,
            mode: .batch(speakers: arguments.speakers),
            stateStore: stateStore,
            stageRunner: StageRunner(stateStore: stateStore, stageEventLogger: StageEventLogger(stateStore: stateStore)),
            telemetryRecorder: TelemetryRecorder(stateStore: stateStore),
            glossary: vaultGlossary(),
        )
        if let message = status.message {
            writeStderr("attribute: \(message)")
        }
        if status.code != WorkerExitCode.success {
            throw ExitCode(status.code)
        }
    }

    private func openStateStore() throws -> StateStore {
        do {
            return try StateStore.subprocess()
        } catch {
            let cause = (error as? StateStoreError).map { String(describing: $0) } ?? String(describing: type(of: error))
            throw failure("could not open the state store (\(cause)).")
        }
    }

    /// Empty when no vault is configured or it cannot be read: the glossary
    /// only decides the spelling of a name, never whether attribution runs.
    private func vaultGlossary() -> Glossary {
        guard let vaultPath = try? Config.load().vaultPath else { return Glossary() }
        return VaultGlossaryBuilder(vaultPath: vaultPath).buildOrEmpty()
    }

    private func failure(_ message: String) -> ExitCode {
        writeStderr("attribute: \(message)")
        return ExitCode(1)
    }
}
