import Foundation

/// The transcribe stage's retry policy (Decision 4.2): one retry, in a fresh
/// subprocess, after a failure a fresh process might not repeat. A crash or
/// an out-of-memory kill takes the whole worker down, so the retry has to be
/// a new process rather than a second call in the same one.
///
/// The policy owns no process. Each attempt is a closure the caller backs
/// with whatever runs the worker, and the policy only decides, from how that
/// attempt ended, whether to run another. That keeps it testable without
/// spawning anything.
public enum TranscribeRetryPolicy {
    /// One initial attempt and one retry.
    public static let maximumAttempts = 2

    /// How one attempt's process ended.
    public enum Termination: Sendable, Equatable {
        case exited(Int32)
        /// Killed by a signal. A crash or the kernel's out-of-memory kill is
        /// worth a retry; `SIGINT`, `SIGTERM`, `SIGHUP` and `SIGQUIT` are the
        /// user or the parent cancelling the worker (Ctrl-C, a stop request, a
        /// closed terminal, a quit), and are not. A process that dies this way
        /// never gets to record its own failure.
        case signaled(Int32)

        var isSuccess: Bool {
            self == .exited(0)
        }

        var isRetryable: Bool {
            switch self {
            case let .exited(status): status == TranscribeStage.retryableExitCode
            case let .signaled(signal): !Self.cancellationSignals.contains(signal)
            }
        }

        /// Relaunching a worker the user just cancelled would undo the cancel.
        private static let cancellationSignals: Set<Int32> = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
    }

    public enum Outcome: Sendable, Equatable {
        case succeeded(attempts: Int)
        /// An attempt failed in a way a retry would not change, so none was
        /// made.
        case failed(attempts: Int, termination: Termination)
        /// Every attempt failed in a way that could have been transient. The
        /// caller records the failure. When `lastTermination` is a signal
        /// there is no failure row from the worker itself, and the stale
        /// active-state sweep is what eventually closes the meeting out.
        case exhausted(attempts: Int, lastTermination: Termination)
    }

    /// Runs `attempt` with the 1-based attempt number until one succeeds, one
    /// fails permanently, or `maximumAttempts` retryable failures have been
    /// spent. An error `attempt` throws is not a termination and is
    /// propagated: a worker that could not even be launched is not something
    /// a second launch is assumed to fix.
    public static func run(
        attempt: @Sendable (_ attemptNumber: Int) async throws -> Termination,
    ) async rethrows -> Outcome {
        var attempts = 0
        while true {
            attempts += 1
            let termination = try await attempt(attempts)
            if termination.isSuccess {
                return .succeeded(attempts: attempts)
            }
            guard termination.isRetryable else {
                return .failed(attempts: attempts, termination: termination)
            }
            if attempts >= maximumAttempts {
                return .exhausted(attempts: attempts, lastTermination: termination)
            }
        }
    }
}
