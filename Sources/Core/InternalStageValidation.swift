/// The `__internal-stage` subprocess protocol's structured mismatch payload
/// (AR-PIPE-7). Deliberately separate from the NFR-I7 `--json` error schema
/// (`schemaVersion` plus `error.summary`/`cause`/`fix`/`see`): that shape is
/// the versioned contract for the 10 user-facing verbs, and this subcommand
/// is explicitly outside it.
public struct WorkerProtocolVersionMismatch: Encodable, Sendable, Equatable {
    public let error = "worker_protocol_version_mismatch"
    public let expected: Int
    public let received: Int

    public init(expected: Int, received: Int) {
        self.expected = expected
        self.received = received
    }
}

/// The three outcomes validating an `__internal-stage <stage> <id>
/// --worker-protocol-version <n>` invocation can reach, before falling
/// through to the same stub every other verb uses.
public enum InternalStageValidation: Sendable, Equatable {
    case valid
    case unknownStage(String)
    case protocolVersionMismatch(WorkerProtocolVersionMismatch)
}

public enum InternalStageValidator {
    /// Stage validity is checked before protocol version (an unrecognized
    /// stage is a plain user/caller error, exit 1; a version mismatch is
    /// this protocol's own state error, exit 2) — order matters when a
    /// caller manages to get both wrong at once.
    public static func validate(
        stage: String,
        workerProtocolVersion: Int,
        expectedProtocolVersion: Int = WorkerProtocolVersion.current,
    ) -> InternalStageValidation {
        guard PipelineStage(rawValue: stage) != nil else {
            return .unknownStage(stage)
        }
        guard workerProtocolVersion == expectedProtocolVersion else {
            return .protocolVersionMismatch(
                WorkerProtocolVersionMismatch(
                    expected: expectedProtocolVersion,
                    received: workerProtocolVersion,
                ),
            )
        }
        return .valid
    }
}
