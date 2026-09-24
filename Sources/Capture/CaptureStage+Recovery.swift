import Core
import Foundation
import State
import Telemetry

/// Launch recovery, and the header repair a failed finalize also needs.
extension CaptureStage {
    /// Settles every `recording` row this process has no live capture for.
    /// A WAV holding audio past its header is repaired and the row moves to
    /// `captured` with `reason: recovered_after_interruption`; a missing,
    /// header-only or unrepairable WAV moves it to `capture_failed`
    /// (`interrupted`). A row another writer settled first is skipped.
    public func recoverInterruptedCaptures() async throws -> [CaptureRecoveryOutcome] {
        let orphans = try await stateStore.fetchPending().filter { meeting in
            meeting.state == PipelineState.recording.rawValue
                && MeetingID(ulid: meeting.id).map { live[$0] == nil } ?? false
        }
        var outcomes: [CaptureRecoveryOutcome] = []
        for meeting in orphans {
            guard let meetingID = MeetingID(ulid: meeting.id) else { continue }
            do {
                try await outcomes.append(recover(meeting, meetingID: meetingID))
            } catch {
                Self.log.warn("could not recover an interrupted capture", [
                    "meeting_id": .publicSafe(meeting.id),
                    "reason": .sensitive(String(describing: error)),
                ])
            }
        }
        return outcomes
    }

    private func recover(_ meeting: Meeting, meetingID: MeetingID) async throws -> CaptureRecoveryOutcome {
        let stamp = ISO8601UTC.string(from: now())
        if let duration = Self.repairedDuration(of: meeting) {
            let startedAt = meeting.captureStartedAt.flatMap(ISO8601UTC.date(from:))
            let endedAt = startedAt.map { ISO8601UTC.string(from: $0.addingTimeInterval(duration)) } ?? stamp
            try await stageEventLogger.recordCaptureFinished(
                meetingID: meetingID,
                kind: .completed,
                targetState: .captured,
                occurredAt: stamp,
                endedAt: endedAt,
                durationSeconds: Int(duration.rounded()),
                metadataJSON: Self.encode(CaptureMeta(reason: Self.recoveredReason)),
            )
            Self.log.info("recovered an interrupted capture", ["meeting_id": .publicSafe(meeting.id)])
            return CaptureRecoveryOutcome(meetingID: meetingID, state: .captured)
        }

        try await stageEventLogger.recordCaptureFinished(
            meetingID: meetingID,
            kind: .failed,
            targetState: .captureFailed,
            occurredAt: stamp,
            endedAt: stamp,
            durationSeconds: nil,
            errorMessage: "capture was interrupted before any audio reached disk",
            metadataJSON: Self.encode(CaptureMeta(errorClass: ErrorClass.interrupted)),
        )
        Self.log.warn("an interrupted capture had no audio", ["meeting_id": .publicSafe(meeting.id)])
        return CaptureRecoveryOutcome(meetingID: meetingID, state: .captureFailed)
    }

    /// The recovered duration when the row's WAV holds at least one sample
    /// past its header and the header could be repaired; `nil` otherwise.
    private static func repairedDuration(of meeting: Meeting) -> TimeInterval? {
        guard
            let path = meeting.audioCachePath,
            holdsAudio(atPath: path),
            let duration = try? WAVWriter.repairHeader(at: URL(fileURLWithPath: path)),
            duration > 0
        else { return nil }
        return duration
    }

    /// A session whose `stop()` threw may have left the placeholder header
    /// on audio that did reach disk. Patching it now keeps that audio
    /// playable on a `capture_failed` row, which launch recovery never
    /// revisits. Best effort: the row is failing either way, so a repair
    /// that fails is logged and the failure goes on.
    func repairAudioAfterFailedFinalize(_ meetingID: MeetingID) {
        guard
            let url = try? cacheDirectory(meetingID).appendingPathComponent(AudioImporter.audioFileName),
            Self.holdsAudio(atPath: url.path)
        else { return }
        do {
            _ = try WAVWriter.repairHeader(at: url)
        } catch {
            Self.log.warn("the failed capture's WAV header could not be repaired", [
                "meeting_id": .publicSafe(meetingID.rawValue),
                "reason": .sensitive(String(describing: error)),
            ])
        }
    }

    private static func holdsAudio(atPath path: String) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 else { return false }
        return size > wavHeaderBytes
    }
}
