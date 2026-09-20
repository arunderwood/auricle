import Core
import Foundation
import Orchestrator
import State

/// The `notify` stage: `published` → `awaiting_verification`. It never marks
/// the meeting verified; that is the maintainer's action, not the stage's.
public enum NotifyStage {
    public static func run(
        meetingID: MeetingID,
        title: String,
        notifier: any Notifier,
        stateStore: StateStore,
        stageRunner: StageRunner,
        log: Log = Log(category: "notifications"),
    ) async throws -> StageRunner.StageOutcome {
        try await stageRunner.run(stage: .notify, meetingID: meetingID, activeState: .published) {
            let meeting = try await stateStore.fetchMeeting(id: meetingID.rawValue)
            if let vaultPath = meeting?.vaultNotePath {
                await notifier.fire(meetingID: meetingID, title: title, vaultPath: vaultPath)
            } else {
                log.warn("meeting has no note path; skipping notification", ["meetingID": .publicSafe(meetingID)])
            }
            return .completed(targetState: .awaitingVerification)
        }
    }
}
