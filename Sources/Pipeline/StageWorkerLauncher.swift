import Core
import Foundation
import Orchestrator
import Transcribe

/// Runs a pipeline stage in its own process and reports how it ended. The seam
/// `PipelineRunner` drives subprocess stages through, so its tests substitute
/// a fake and never spawn anything.
public protocol StageWorkerLauncher: Sendable {
    /// Runs `stage` to completion and reports how the worker ended. Cancelling
    /// the calling task terminates the worker and makes this throw
    /// `CancellationError`.
    func run(stage: PipelineStage, meetingID: MeetingID, publishAnyway: Bool) async throws -> TranscribeRetryPolicy.Termination
}

/// Launches `auricle-cli __internal-stage <stage> <id>` through
/// `SubprocessDispatcher` (AR-PIPE-7).
public struct SubprocessStageLauncher: StageWorkerLauncher {
    private let dispatcher: SubprocessDispatcher

    public init(dispatcher: SubprocessDispatcher) {
        self.dispatcher = dispatcher
    }

    public func run(stage: PipelineStage, meetingID: MeetingID, publishAnyway: Bool) async throws -> TranscribeRetryPolicy.Termination {
        try Task.checkCancellation()
        let handle = ProcessHandle()
        let termination = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscribeRetryPolicy.Termination, Error>) in
                do {
                    let process = try dispatcher.dispatch(
                        stage: stage,
                        meetingID: meetingID,
                        publishAnyway: publishAnyway,
                        onExit: { continuation.resume(returning: $0.wasSignaled ? .signaled($0.status) : .exited($0.status)) },
                    )
                    handle.adopt(process)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.terminate()
        }
        try Task.checkCancellation()
        return termination
    }
}

/// Holds the worker so a cancellation that arrives before or after it
/// launches still terminates it.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminationRequested = false

    func adopt(_ launched: Process) {
        let shouldTerminate = lock.withLock {
            process = launched
            return terminationRequested
        }
        if shouldTerminate {
            terminateIfRunning(launched)
        }
    }

    func terminate() {
        let target = lock.withLock {
            terminationRequested = true
            return process
        }
        if let target {
            terminateIfRunning(target)
        }
    }

    private func terminateIfRunning(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
    }
}

public extension SubprocessDispatcher {
    /// The dispatcher for a process that is itself `auricle-cli`. The default
    /// resolver looks for the CLI embedded in the GUI bundle, which an
    /// unbundled CLI is not inside, so workers are the running binary.
    static func forRunningCLI(
        executable: @escaping @Sendable () -> URL? = { Bundle.main.executableURL },
    ) -> SubprocessDispatcher {
        SubprocessDispatcher(resolveExecutablePath: executable)
    }
}
