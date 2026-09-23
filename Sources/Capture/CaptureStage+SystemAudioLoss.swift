import Core
import Foundation
import Telemetry

/// System-audio loss: when the system tap keeps failing, the capture carries
/// on with the microphone and a backoff keeps trying to bring the tap back.
/// Losing system audio never fails a capture by itself; losing it with no
/// microphone to fall back on does, as `all_sources_lost`.
extension CaptureStage {
    func loseSystemAudio(_ meetingID: MeetingID, reason: String) async {
        guard let capture = live[meetingID], case .running = capture.phase else { return }
        live[meetingID]?.systemAudioLost = true
        live[meetingID]?.systemAudioLoss.lostAt = now()
        live[meetingID]?.systemAudioLoss.count += 1
        Self.log.warn("system audio lost; recording the microphone only", ["meeting_id": .publicSafe(meetingID.rawValue)])

        guard capture.micIncluded else {
            await fail(
                meetingID,
                errorClass: ErrorClass.allSourcesLost,
                source: .systemAudio,
                error: CaptureError.streamInterrupted(reason: reason),
            )
            return
        }
        let session = capture.session
        let delay = systemAudioRetryDelay
        let sleep = sleep
        live[meetingID]?.systemAudioRetries = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let wait = delay(attempt)
                do {
                    try await sleep(wait)
                } catch {
                    return
                }
                guard let self, await !self.retrySystemAudio(meetingID, session: session, attempt: attempt, waited: wait) else { return }
                attempt += 1
            }
        }
    }

    /// One backoff attempt. Returns `true` when the backoff is over: system
    /// audio is back, or the capture is no longer running.
    private func retrySystemAudio(_ meetingID: MeetingID, session: any CaptureRecording, attempt: Int, waited: Duration) async -> Bool {
        guard isStillLosingSystemAudio(meetingID) else { return true }
        let (seconds, attoseconds) = waited.components
        await recordRetry(
            CaptureMeta(
                source: CaptureSource.systemAudio.rawValue,
                attemptNumber: attempt + 1,
                previousErrorClass: RetryCause.systemAudioLost,
                backoffMS: Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000),
            ),
            for: meetingID,
            reason: "system audio lost; backoff attempt \(attempt + 1)",
        )
        guard isStillLosingSystemAudio(meetingID) else { return true }
        do {
            try await session.restart(.systemAudio)
        } catch {
            return !isStillLosingSystemAudio(meetingID)
        }
        guard isStillLosingSystemAudio(meetingID) else { return true }
        live[meetingID]?.systemAudioLost = false
        live[meetingID]?.systemAudioLoss.restoredAt = now()
        live[meetingID]?.systemPolicy = TransientRestartPolicy()
        live[meetingID]?.systemAudioRetries = nil
        Self.log.info("system audio restored", ["meeting_id": .publicSafe(meetingID.rawValue)])
        return true
    }

    /// Whether `meetingID` is a live capture recording the microphone only.
    func systemAudioIsLost(_ meetingID: MeetingID) -> Bool {
        live[meetingID]?.systemAudioLost ?? false
    }

    private func isStillLosingSystemAudio(_ meetingID: MeetingID) -> Bool {
        guard let capture = live[meetingID], case .running = capture.phase else { return false }
        return capture.systemAudioLost
    }
}
