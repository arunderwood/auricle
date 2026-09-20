import Core
import Foundation

/// Spawns a stage as its own `auricle-cli __internal-stage` subprocess
/// (AR-PIPE-7), the mechanism both the GUI and `CrashRecovery` use to
/// re-run a stage out-of-process. `resolveExecutablePath` is injectable
/// (AR-PAT-8) because the real `auricle-cli` binary doesn't exist until
/// Story 1.7 — production resolves it via `Bundle.main`, tests substitute a
/// stub executable so `dispatch` can actually spawn and exit without a real
/// worker behind it.
///
/// `resolveVaultPath` is injectable for the same reason: the worker is a
/// separate process with no view of the dispatcher's configuration, so the
/// vault has to travel on its argument vector, and tests must not read the
/// real `~/.auricle/config.toml` to build one.
public struct SubprocessDispatcher: Sendable {
    public enum DispatchError: Error, Sendable, Equatable {
        case executableNotFound
    }

    private static let log = Log(category: "orchestrator")

    private let resolveExecutablePath: @Sendable () -> URL?
    private let resolveVaultPath: @Sendable () -> String?

    public init(
        resolveExecutablePath: @escaping @Sendable () -> URL? = {
            Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")
        },
        resolveVaultPath: @escaping @Sendable () -> String? = SubprocessDispatcher.configuredVaultPath,
    ) {
        self.resolveExecutablePath = resolveExecutablePath
        self.resolveVaultPath = resolveVaultPath
    }

    /// An unreadable config file costs the worker its glossary, not the
    /// dispatch: a vocabulary is an aid to the summary, never a reason to
    /// withhold it. The warning names the failure's type only, because the
    /// path in a config file is the user's own.
    @Sendable
    public static func configuredVaultPath() -> String? {
        do {
            return try Config.load().vaultPath?.path
        } catch {
            log.warn("config unreadable; dispatching without a vault path", ["errorType": .publicSafe(String(describing: type(of: error)))])
            return nil
        }
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
        process.arguments = InternalStageArguments(
            stage: stage.rawValue,
            id: meetingID.rawValue,
            workerProtocolVersion: workerProtocolVersion,
            vaultPath: resolveVaultPath(),
        ).arguments
        return process
    }

    /// Builds and launches the subprocess. `onExit`, when given, is called
    /// once with how the process ended. It is installed before `run()`, so
    /// no exit can precede it, and it receives values only, never the
    /// `Process`. It runs on a queue Foundation chooses, not the caller's. A
    /// caller that wants to block on completion instead can `waitUntilExit()`
    /// on the result.
    @discardableResult
    public func dispatch(
        stage: PipelineStage,
        meetingID: MeetingID,
        workerProtocolVersion: Int = Core.WorkerProtocolVersion.current,
        onExit: (@Sendable (WorkerExit) -> Void)? = nil,
    ) throws -> Process {
        let process = try makeProcess(stage: stage, meetingID: meetingID, workerProtocolVersion: workerProtocolVersion)
        if let onExit {
            process.terminationHandler = { finished in
                onExit(WorkerExit(stage: stage, meetingID: meetingID, status: finished.terminationStatus))
            }
        }
        try process.run()
        return process
    }
}

/// How a dispatched worker ended. `status` is the exit code, or the signal
/// number when the process was killed by a signal; either way non-zero means
/// the worker did not finish its stage.
public struct WorkerExit: Sendable, Equatable {
    public let stage: PipelineStage
    public let meetingID: MeetingID
    public let status: Int32

    public init(stage: PipelineStage, meetingID: MeetingID, status: Int32) {
        self.stage = stage
        self.meetingID = meetingID
        self.status = status
    }
}
