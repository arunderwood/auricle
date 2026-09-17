import Core
import Foundation

/// Spawns a stage as its own `auricle-cli __internal-stage` subprocess
/// (AR-PIPE-7), the mechanism both the GUI and `CrashRecovery` use to
/// re-run a stage out-of-process. `resolveExecutablePath` is injectable
/// (AR-PAT-8) because the real `auricle-cli` binary doesn't exist until
/// Story 1.7 — production resolves it via `Bundle.main`, tests substitute a
/// stub executable so `dispatch` can actually spawn and exit without a real
/// worker behind it.
public struct SubprocessDispatcher: Sendable {
    public enum DispatchError: Error, Sendable, Equatable {
        case executableNotFound
    }

    private let resolveExecutablePath: @Sendable () -> URL?

    public init(resolveExecutablePath: @escaping @Sendable () -> URL? = {
        Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")
    }) {
        self.resolveExecutablePath = resolveExecutablePath
    }

    /// Builds the `Process` `dispatch` would run, without running it — the
    /// seam `SubprocessDispatcherTests` uses to assert the executable path
    /// and argument vector are correct without spawning anything.
    public func makeProcess(
        stage: PipelineStage,
        meetingID: MeetingID,
        workerProtocolVersion: Int = Core.WorkerProtocolVersion.current,
    ) throws -> Process {
        guard let executableURL = resolveExecutablePath() else {
            throw DispatchError.executableNotFound
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "__internal-stage",
            stage.rawValue,
            meetingID.rawValue,
            "--worker-protocol-version", String(workerProtocolVersion),
        ]
        return process
    }

    /// Builds and launches the subprocess. Callers that only need to observe
    /// completion (rather than block on it) should read `process.terminationHandler`
    /// or await `process.waitUntilExit()` on the result themselves — this
    /// method's job is spawning, not supervising.
    @discardableResult
    public func dispatch(
        stage: PipelineStage,
        meetingID: MeetingID,
        workerProtocolVersion: Int = Core.WorkerProtocolVersion.current,
    ) throws -> Process {
        let process = try makeProcess(stage: stage, meetingID: meetingID, workerProtocolVersion: workerProtocolVersion)
        try process.run()
        return process
    }
}
