import Core
import Foundation
import Notifications
import Orchestrator
import State
import Telemetry

/// Hands the GUI's captured meetings to the pipeline: each one as its
/// capture stops, and at launch any that a quit or an unreadable config left
/// `captured` without a run.
///
/// Only a meeting `CaptureStage.stop()` landed is run. A meeting launch
/// recovery relabelled `recovered_after_interruption`, and one `auricle
/// import` created, stay `captured` until the user runs them. A meeting
/// stranded mid-pipeline, in `transcribing` or later, is not this type's.
public struct CapturePipelineLauncher: Sendable {
    /// Where the automatic run stops: `review-diarization` leaves the meeting
    /// `awaiting_attribution`, because naming the speakers is the user's step.
    public static let runTarget: RunStage = .reviewDiarization

    private static let log = Log(category: "capture-pipeline")

    private let stateStore: StateStore
    private let launcher: any StageWorkerLauncher
    private let notifier: any Notifier
    private let loadConfig: @Sendable () throws -> Config

    /// `loadConfig` is read at every run, so a config fixed after one failed
    /// run is used by the next.
    public init(
        stateStore: StateStore,
        launcher: any StageWorkerLauncher,
        notifier: any Notifier,
        loadConfig: @escaping @Sendable () throws -> Config = { try Config.load() },
    ) {
        self.stateStore = stateStore
        self.launcher = launcher
        self.notifier = notifier
        self.loadConfig = loadConfig
    }

    /// Runs one captured meeting to `runTarget`. Never throws: it runs after
    /// the user's stop has already returned, so every failure is logged, and
    /// a meeting whose run never started stays `captured` for the next
    /// launch to retry. No glossary: only attribute reads one, and this run
    /// stops before attribute. `nil` when the config could not be read.
    @discardableResult
    public func runAfterCapture(_ meetingID: MeetingID) async -> RunResult? {
        let config: Config
        do {
            config = try loadConfig()
        } catch {
            Self.log.warn("config unreadable; the captured meeting stays captured until the next launch", [
                "meeting_id": .publicSafe(meetingID.rawValue),
                "error_type": .publicSafe(String(describing: type(of: error))),
            ])
            return nil
        }
        let runner = PipelineRunner(environment: PipelineRunner.Environment(
            stateStore: stateStore,
            launcher: launcher,
            notifier: notifier,
            vaultPath: config.vaultPath,
            meetingsSubdir: config.meetingsSubdir,
        ))
        let result = await runner.run(meetingID: meetingID, options: RunOptions(to: Self.runTarget))
        if result.exitCode != WorkerExitCode.success {
            Self.log.warn("the pipeline stopped after capture", [
                "meeting_id": .publicSafe(meetingID.rawValue),
                "exit_code": .publicSafe(result.exitCode),
            ])
        }
        return result
    }

    /// Runs, one at a time, every `captured` meeting whose latest capture
    /// `completed` event is the one `stop()` writes (`CaptureMeta.isStoppedCapture`).
    /// A meeting that cannot be read is logged and skipped, and the rest
    /// still run. Returns the meetings it ran.
    @discardableResult
    public func resumeStrandedCaptures() async -> [MeetingID] {
        let pending: [Meeting]
        do {
            pending = try await stateStore.fetchPending()
        } catch {
            Self.log.error("could not list captured meetings to resume", ["reason": .sensitive(String(describing: error))])
            return []
        }
        var resumed: [MeetingID] = []
        for meeting in pending where meeting.state == PipelineState.captured.rawValue {
            guard let meetingID = MeetingID(ulid: meeting.id) else { continue }
            do {
                guard try await wasStopped(meetingID) else { continue }
            } catch {
                Self.log.warn("could not read a captured meeting's capture event", [
                    "meeting_id": .publicSafe(meeting.id),
                    "reason": .sensitive(String(describing: error)),
                ])
                continue
            }
            resumed.append(meetingID)
            await runAfterCapture(meetingID)
        }
        return resumed
    }

    private func wasStopped(_ meetingID: MeetingID) async throws -> Bool {
        let events = try await stateStore.fetchStageEvents(meetingID: meetingID.rawValue)
        guard
            let latest = events.last(where: {
                $0.stage == PipelineStage.capture.rawValue && $0.event == StageEventKind.completed.rawValue
            }),
            let json = latest.metadataJSON
        else { return false }
        return try JSONDecoder().decode(CaptureMeta.self, from: Data(json.utf8)).isStoppedCapture
    }
}
