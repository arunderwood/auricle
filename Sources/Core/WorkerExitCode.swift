/// The exit statuses of an `auricle-cli __internal-stage` worker process
/// (architecture.md Decision 1.5). Named once so the worker that returns them
/// and the code that reads them cannot drift.
public enum WorkerExitCode {
    public static let success: Int32 = 0
    /// The caller passed something invalid: an unknown stage, a malformed id.
    public static let callerError: Int32 = 1
    /// The state store could not be read or written, or the stage failed in a
    /// way a retry would not change.
    public static let stateError: Int32 = 2
    /// There is no meeting with the id the caller gave.
    public static let meetingNotFound: Int32 = 3
    /// The command line did not parse (`EX_USAGE` in `sysexits.h`).
    public static let usage: Int32 = 64
    /// A failure a fresh process may not repeat (`EX_TEMPFAIL`). It is what
    /// tells the caller a retry is worth making.
    public static let retryable: Int32 = 75
}

/// How a worker process should end. `message` is a fixed sentence or a type
/// name, never an error's own text, because the caller writes it to stderr
/// and a foreign error can embed a path or transcript text.
public struct WorkerExitStatus: Sendable, Equatable {
    public let code: Int32
    public let message: String?

    public init(code: Int32, message: String? = nil) {
        self.code = code
        self.message = message
    }
}
