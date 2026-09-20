import ArgumentParser
import Core
import Foundation

/// The command line of `auricle-cli __internal-stage` (AR-PIPE-7), declared
/// once for both ends of the wire: `SubprocessDispatcher` builds its argument
/// vector with `arguments`, and the CLI's `InternalStageWorker` reads it as an
/// `@OptionGroup` of this same type, so a renamed option cannot make the
/// dispatcher and the worker disagree without a test noticing.
public struct InternalStageArguments: ParsableArguments {
    /// The subcommand name, shared by the argument vector and the CLI's
    /// `CommandConfiguration`.
    public static let commandName = "__internal-stage"

    @Argument(help: "Pipeline stage to run.")
    public var stage: String

    @Argument(help: "Meeting ID.")
    public var id: String

    @Option(help: "Protocol version the dispatching process was built against.")
    public var workerProtocolVersion: Int

    @Option(help: "Obsidian vault whose page names and wikilinks become the summarize stage's glossary.")
    public var vaultPath: String?

    public init() {}

    public init(stage: String, id: String, workerProtocolVersion: Int, vaultPath: String? = nil) {
        self.stage = stage
        self.id = id
        self.workerProtocolVersion = workerProtocolVersion
        self.vaultPath = vaultPath
    }

    /// The argument vector, subcommand name first, that parses back to these
    /// values.
    public var arguments: [String] {
        var vector = [Self.commandName, stage, id, "--worker-protocol-version", String(workerProtocolVersion)]
        if let vaultPath {
            vector += ["--vault-path", vaultPath]
        }
        return vector
    }

    /// What the worker should do once the arguments have parsed.
    public enum Decision: Sendable, Equatable {
        case run(stage: PipelineStage, meetingID: MeetingID)
        /// End the process now without running a stage. `message` is the
        /// complete line for stderr, prefix included.
        case exit(WorkerExitStatus)
    }

    /// Validates in a fixed order, so a caller that gets several things wrong
    /// gets a stable answer: stage (a caller error), then protocol version (a
    /// state error: the two sides disagree about the protocol), then the id
    /// (a caller error). The id is checked before any stage starts, so a
    /// malformed one never opens the state store.
    public func decide(expectedProtocolVersion: Int = WorkerProtocolVersion.current) -> Decision {
        switch InternalStageValidator.validate(
            stage: stage,
            workerProtocolVersion: workerProtocolVersion,
            expectedProtocolVersion: expectedProtocolVersion,
        ) {
        case .valid:
            break
        case let .unknownStage(unknown):
            return .exit(Self.callerError("unrecognized stage '\(unknown)'."))
        case let .protocolVersionMismatch(mismatch):
            return .exit(WorkerExitStatus(code: WorkerExitCode.stateError, message: Self.description(of: mismatch)))
        }

        guard let meetingID = MeetingID(ulid: id) else {
            return .exit(Self.callerError("'\(id)' is not a valid meeting ID."))
        }
        // The validator has already accepted the stage, so this cannot fail;
        // the fallback keeps the type honest without a trap.
        guard let pipelineStage = PipelineStage(rawValue: stage) else {
            return .exit(Self.callerError("unrecognized stage '\(stage)'."))
        }
        return .run(stage: pipelineStage, meetingID: meetingID)
    }

    private static func callerError(_ detail: String) -> WorkerExitStatus {
        WorkerExitStatus(code: WorkerExitCode.callerError, message: "\(commandName): \(detail)")
    }

    /// The JSON payload the protocol defines for a mismatch, bare on stderr so
    /// a reader can parse the line as it stands; plain text only if encoding
    /// fails. Keys are sorted so the line is the same every time.
    private static func description(of mismatch: WorkerProtocolVersionMismatch) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(mismatch), let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\(commandName): worker protocol version mismatch (expected \(mismatch.expected), received \(mismatch.received))."
    }
}
