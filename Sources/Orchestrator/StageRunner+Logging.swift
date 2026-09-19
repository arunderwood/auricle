import Core
import Telemetry

extension StageRunner {
    /// One record per transition: error level for a move into a `*_failed`
    /// state, info for every other. `errorClass` is a stage's own stable
    /// identifier; `errorMessage` is never logged, because a foreign error's
    /// text can embed a path or transcript text.
    func logTransition(
        meetingID: MeetingID,
        stage: PipelineStage,
        kind: StageEventKind,
        state: PipelineState,
        durationMS: Int? = nil,
        errorClass: String? = nil,
    ) {
        var fields: [String: LogSensitivity] = [
            "meetingID": .publicSafe(meetingID),
            "stage": .publicSafe(stage.rawValue),
            "event": .publicSafe(kind.rawValue),
            "state": .publicSafe(state.rawValue),
        ]
        if let durationMS {
            fields["durationMS"] = .publicSafe(durationMS)
        }
        if let errorClass {
            fields["errorClass"] = .publicSafe(errorClass)
        }
        if state.isFailed {
            log.error("stage moved a meeting into a failed state", fields)
        } else {
            log.info("stage transition", fields)
        }
    }

    /// A transition `PipelineTransitions` refuses is a programming error in the
    /// stage, so it is logged at error before the throw: nothing else records it,
    /// since no stage event is written for it. All fields are stable identifiers.
    func logRejectedTransition(
        _ message: StaticString,
        meetingID: MeetingID,
        stage: PipelineStage,
        activeState: PipelineState,
        targetState: PipelineState? = nil,
    ) {
        var fields: [String: LogSensitivity] = [
            "meetingID": .publicSafe(meetingID),
            "stage": .publicSafe(stage.rawValue),
            "activeState": .publicSafe(activeState.rawValue),
        ]
        if let targetState {
            fields["targetState"] = .publicSafe(targetState.rawValue)
        }
        log.error(message, fields)
    }
}
