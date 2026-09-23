@testable import Capture
import Core
import Foundation
import GRDB
import Notifications
@testable import State
import Telemetry
import Testing

// MARK: - Start

@Test func startWritesARecordingRowWithItsZoneAndOneStartedEvent() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording())

    let result = try await stage.start(meetingID: fixture.id)

    #expect(result == CaptureStartResult(meetingID: fixture.id, micIncluded: true))
    let meeting = try await fixture.meeting(fixture.id)
    #expect(meeting.state == "recording")
    #expect(meeting.captureStartedAt == ISO8601UTC.string(from: fixture.clock.value))
    #expect(meeting.audioCachePath == fixture.audioURL(fixture.id).path)
    #expect(meeting.captureTimeZone == TimeZone.current.identifier)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.stage) == ["capture"])
    #expect(events.map(\.event) == ["started"])
}

@Test func aDeniedMicrophoneStillStartsAndIsReported() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let zone = try #require(TimeZone(identifier: "Pacific/Auckland"))
    let stage = fixture.stage(session: fixture.recording(micIncluded: false), timeZone: zone)

    let result = try await stage.start(meetingID: fixture.id)

    #expect(!result.micIncluded)
    let meeting = try await fixture.meeting(fixture.id)
    #expect(meeting.state == "recording")
    #expect(meeting.captureTimeZone == "Pacific/Auckland")
}

@Test func aSessionThatFailsToStartLeavesACaptureFailedRowAndRethrows() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording(startError: FakeFailure(description: "no tap")))

    await #expect(throws: FakeFailure.self) {
        _ = try await stage.start(meetingID: fixture.id)
    }

    #expect(try await fixture.meeting(fixture.id).state == "capture_failed")
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "failed"])
    #expect(try metadata(events.last).errorClass == "start_failed")
}

// MARK: - Stop

@Test func stopMovesTheCaptureToCapturedWithItsMetadataAndHandsItOn() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    session.stats.value = CaptureWatchdogStats(exactZeroSeconds: 12.5, rebuildCount: 2)
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 3, for: fixture.id)
    fixture.clock.value = fixture.clock.value.addingTimeInterval(4)

    let state = try await stage.stop(meetingID: fixture.id)

    #expect(state == .captured)
    let meeting = try await fixture.meeting(fixture.id)
    #expect(meeting.state == "captured")
    #expect(meeting.captureEndedAt == ISO8601UTC.string(from: fixture.clock.value))
    #expect(meeting.durationSeconds == 3)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(try metadata(events.last) == CaptureMeta(micIncluded: true, exactZeroSeconds: 12.5, tapRebuilds: 2))
    try await eventually { fixture.captured.value == [fixture.id] }
}

@Test func aSecondStopReturnsTheRowsStateAndWritesNothing() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording())
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)
    _ = try await stage.stop(meetingID: fixture.id)

    #expect(try await stage.stop(meetingID: fixture.id) == .captured)
    #expect(try await fixture.events(fixture.id).map(\.event) == ["started", "completed"])
}

@Test func stoppingAMeetingThatDoesNotExistIsMeetingNotFound() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: nil)

    await #expect(throws: StateStoreError.meetingNotFound(id: fixture.id.rawValue)) {
        _ = try await stage.stop(meetingID: fixture.id)
    }
}

@Test func aSessionThatCannotFinalizeFailsTheCaptureAsInterrupted() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording(stopError: FakeFailure(description: "disk gone")))
    _ = try await stage.start(meetingID: fixture.id)

    #expect(try await stage.stop(meetingID: fixture.id) == .captureFailed)

    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "failed"])
    #expect(try metadata(events.last).errorClass == "interrupted")
    #expect(fixture.captured.value.isEmpty)
}

// MARK: - Recovery

@Test func recoveryRepairsAnInterruptedWAVAndMovesTheRowToCaptured() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    _ = try await fixture.stage(session: fixture.recording()).start(meetingID: fixture.id)
    // What a crash leaves: samples on disk, the placeholder header never
    // patched.
    do {
        let writer = try WAVWriter(meetingID: fixture.id, cacheDirectory: { fixture.root.appendingPathComponent($0.rawValue, isDirectory: true) })
        try writer.write(Data(count: 2 * AudioImporter.sampleRate * 2))
    }

    let outcomes = try await fixture.stage(session: nil).recoverInterruptedCaptures()

    #expect(outcomes == [CaptureRecoveryOutcome(meetingID: fixture.id, state: .captured)])
    let meeting = try await fixture.meeting(fixture.id)
    #expect(meeting.state == "captured")
    #expect(meeting.durationSeconds == 2)
    let startedAt = try #require(meeting.captureStartedAt.flatMap(ISO8601UTC.date(from:)))
    #expect(meeting.captureEndedAt == ISO8601UTC.string(from: startedAt.addingTimeInterval(2)))
    #expect(meeting.audioCachePath == fixture.audioURL(fixture.id).path)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(try metadata(events.last).reason == "recovered_after_interruption")

    let header = try Data(contentsOf: fixture.audioURL(fixture.id)).subdata(in: 40 ..< 44)
    #expect(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == UInt32(2 * AudioImporter.sampleRate * 2).littleEndian)
    #expect(fixture.captured.value.isEmpty)
}

@Test(arguments: ["missing", "header-only", "not-a-wav"])
func recoveryWithoutUsableAudioFailsTheCaptureAsInterrupted(audio: String) async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    _ = try await fixture.stage(session: fixture.recording()).start(meetingID: fixture.id)
    let url = fixture.audioURL(fixture.id)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    switch audio {
    case "header-only":
        _ = try WAVWriter(meetingID: fixture.id, cacheDirectory: { fixture.root.appendingPathComponent($0.rawValue, isDirectory: true) })
    case "not-a-wav":
        try AtomicWriter.write(Data(repeating: 0x41, count: 4096), to: url)
    default:
        break
    }

    let outcomes = try await fixture.stage(session: nil).recoverInterruptedCaptures()

    #expect(outcomes == [CaptureRecoveryOutcome(meetingID: fixture.id, state: .captureFailed)])
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "failed"])
    #expect(try metadata(events.last).errorClass == "interrupted")
}

@Test func recoveryLeavesALiveCaptureAlone() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording())
    _ = try await stage.start(meetingID: fixture.id)

    #expect(try await stage.recoverInterruptedCaptures().isEmpty)
    #expect(try await fixture.meeting(fixture.id).state == "recording")
}

// MARK: - Faults

@Test func aReportedRevocationSavesTheAudioFailsTheCaptureAndNotifies() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.permissionRevoked(.microphone))
    try await eventually { try await fixture.meeting(fixture.id).state == "capture_failed" }

    #expect(session.stopCount.value == 1)
    #expect(try await fixture.meeting(fixture.id).audioCachePath == fixture.audioURL(fixture.id).path)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "failed"])
    let meta = try metadata(events.last)
    #expect(meta.errorClass == "permission_revoked_midstream")
    #expect(meta.source == "microphone")
    try await eventually { !fixture.notifier.captureFailures.value.isEmpty }
    #expect(fixture.notifier.captureFailures.value.map(\.0) == [fixture.id])
    #expect(fixture.notifier.captureFailures.value.map(\.1) == [.permissionRevokedMidstream])
    #expect(try await stage.stop(meetingID: fixture.id) == .captureFailed)
}

/// Each input has its own cap: a system fault does not count toward the
/// microphone's three.
@Test func twoMicrophoneFaultsRestartInlineAndTheThirdFailsTheCapture() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.transient(.systemAudio, reason: "device lost"))
    session.emit(.transient(.microphone, reason: "engine stopped"))
    session.emit(.transient(.microphone, reason: "engine stopped again"))
    try await eventually { session.restarts.value.count == 3 }
    #expect(session.restarts.value == [.systemAudio, .microphone, .microphone])
    try await eventually { try await fixture.events(fixture.id).count == 4 }
    let retried = try await fixture.events(fixture.id).filter { $0.event == "retried" }
    let retriedMeta = try retried.map { try metadata($0) }
    #expect(retriedMeta.map(\.source) == ["system_audio", "microphone", "microphone"])
    // Numbered per source: the system fault does not count toward the mic's.
    #expect(retriedMeta.map(\.attemptNumber) == [1, 1, 2])
    #expect(retriedMeta.allSatisfy { $0.previousErrorClass == "stream_interrupted" && $0.backoffMS == 0 })
    #expect(try await fixture.meeting(fixture.id).state == "recording")

    session.emit(.transient(.microphone, reason: "engine stopped a third time"))
    try await eventually { try await fixture.meeting(fixture.id).state == "capture_failed" }

    #expect(session.restarts.value.count == 3)
    #expect(session.stopCount.value == 1)
    let events = try await fixture.events(fixture.id)
    #expect(events.map(\.event) == ["started", "retried", "retried", "retried", "failed"])
    #expect(try metadata(events.last).errorClass == "transient_stream_errors")
    #expect(fixture.notifier.captureFailures.value.isEmpty)
}

@Test func aRestartThatThrowsCountsAsTheNextFault() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    session.restartErrors.value = [FakeFailure(description: "engine start failed")]
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.transient(.microphone, reason: "engine stopped"))
    try await eventually { session.restarts.value.count == 2 }
    try await eventually { try await fixture.events(fixture.id).count == 3 }
    #expect(try await fixture.meeting(fixture.id).state == "recording")

    session.emit(.transient(.microphone, reason: "engine stopped again"))
    try await eventually { try await fixture.meeting(fixture.id).state == "capture_failed" }
    #expect(try await metadata(fixture.events(fixture.id).last).errorClass == "transient_stream_errors")
}

@Test func aMicrophoneRestartThatFindsTheGrantRevokedFailsAsARevocation() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    session.restartErrors.value = [CaptureError.permissionRevokedMidstream]
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.transient(.microphone, reason: "engine stopped"))
    try await eventually { try await fixture.meeting(fixture.id).state == "capture_failed" }

    #expect(try await metadata(fixture.events(fixture.id).last).errorClass == "permission_revoked_midstream")
    try await eventually { fixture.notifier.captureFailures.value.count == 1 }
}

/// A fault that arrives while `stop` is still finalizing meets a capture
/// that has left `.running`, and is ignored.
@Test func aFaultDuringStopIsIgnored() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let gate = Gate()
    let session = fixture.recording(stopGate: gate)
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)

    let stopping = Task { try await stage.stop(meetingID: fixture.id) }
    try await eventually { gate.reached.value }
    session.emit(.transient(.systemAudio, reason: "device lost"))
    session.emit(.permissionRevoked(.microphone))
    try await Task.sleep(for: .milliseconds(50))
    gate.release()

    #expect(try await stopping.value == .captured)
    #expect(try await fixture.events(fixture.id).map(\.event) == ["started", "completed"])
    #expect(session.restarts.value.isEmpty)
    #expect(session.stopCount.value == 1)
    #expect(fixture.notifier.captureFailures.value.isEmpty)
}

/// A stop that arrives while the session is still starting returns
/// `recording`, and is carried out once the start completes.
@Test func aStopDuringStartIsCarriedOutOnceTheSessionHasStarted() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let gate = Gate()
    let stage = fixture.stage(session: fixture.recording(startGate: gate))
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)

    let starting = Task { try await stage.start(meetingID: fixture.id) }
    try await eventually { gate.reached.value }
    #expect(try await stage.stop(meetingID: fixture.id) == .recording)
    gate.release()

    #expect(try await starting.value == CaptureStartResult(meetingID: fixture.id, micIncluded: true))
    #expect(try await fixture.meeting(fixture.id).state == "captured")
    #expect(try await fixture.events(fixture.id).map(\.event) == ["started", "completed"])
    try await eventually { fixture.captured.value == [fixture.id] }
}

// MARK: - One capture at a time

@Test(arguments: [true, false])
func aSecondStartWhileACaptureIsLiveIsRefusedAndWritesNothing(sameID: Bool) async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording())
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)
    let secondID = sameID ? fixture.id : MeetingID.generate()

    await #expect(throws: CaptureStageError.captureAlreadyLive(meetingID: fixture.id)) {
        _ = try await stage.start(meetingID: secondID)
    }

    if sameID {
        #expect(try await fixture.events(fixture.id).map(\.event) == ["started"])
    } else {
        #expect(try await fixture.store.fetchMeeting(id: secondID.rawValue) == nil)
        #expect(try await fixture.events(secondID).isEmpty)
    }
    #expect(try await stage.stop(meetingID: fixture.id) == .captured)
    #expect(try await fixture.events(fixture.id).map(\.event) == ["started", "completed"])
}
