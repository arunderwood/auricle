import ArgumentParser
import Core
import Foundation

// AR-PIPE-7: the GUI's and `CrashRecovery`'s subprocess-dispatch mechanism,
// not a user-facing verb — `shouldDisplay: false` keeps it out of `auricle
// help` and shell-completion scripts, and it is explicitly exempt from the
// NFR-I7 binding-contract guarantee every other verb carries.
struct InternalStageWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__internal-stage",
        shouldDisplay: false
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
            try notYetImplemented("__internal-stage")

        case .unknownStage(let stage):
            writeStderr("__internal-stage: unrecognized stage '\(stage)'.")
            throw ExitCode(1)

        case .protocolVersionMismatch(let mismatch):
            if let json = try? JSONEncoder().encode(mismatch),
               let jsonString = String(data: json, encoding: .utf8) {
                writeStderr(jsonString)
            } else {
                writeStderr(
                    "__internal-stage: worker protocol version mismatch "
                        + "(expected \(mismatch.expected), received \(mismatch.received))."
                )
            }
            throw ExitCode(2)
        }
    }
}
