@testable import Capture
import Core
import Foundation
import Testing

private let tapGone = FakeFailure(description: "tap gone")

/// Two inline restarts that throw make the first reported fault the third in
/// the window, which loses system audio. With `waitForLoss` false the caller
/// waits on its own condition, for a backoff that may end the loss before a
/// poll could see it.
private func loseSystemAudio(_ session: FakeRecording, on stage: CaptureStage, _ fixture: StageFixture, waitForLoss: Bool = true) async throws {
    session.restartErrors.value = [tapGone, tapGone] + session.restartErrors.value
    session.emit(.transient(.systemAudio, reason: "device lost"))
    guard waitForLoss else { return }
    try await eventually {
        let lost = await stage.systemAudioIsLost(fixture.id)
        let state = try await fixture.meeting(fixture.id).state
        return lost || state != "recording"
    }
}

@Test func losingSystemAudioKeepsRecordingTheMicrophone() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)

    try await loseSystemAudio(session, on: stage, fixture)
    // The session's watchdog keeps reporting its failing rebuilds; while lost
    // they are ignored.
    session.emit(.transient(.systemAudio, reason: "rebuild failed"))
    session.emit(.transient(.systemAudio, reason: "rebuild failed"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(try await fixture.meeting(fixture.id).state == "recording")
    #expect(session.stopCount.value == 0)
    #expect(session.restarts.value.count == 2)

    #expect(try await stage.stop(meetingID: fixture.id) == .captured)
    #expect(session.stopCount.value == 1)
    let events = try await fixture.events(fixture.id)
    #expect(!events.contains { $0.event == "failed" })
    let meta = try metadata(events.last)
    #expect(meta.systemAudioLostAt == ISO8601UTC.string(from: fixture.clock.value))
    #expect(meta.systemAudioLossCount == 1)
    #expect(meta.systemAudioRestoredAt == nil)
}

@Test func aBackoffRestartThatSucceedsRestoresSystemAudio() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    // The first two backoff attempts fail; the third brings the tap back.
    session.restartErrors.value = [tapGone, tapGone]
    let stage = fixture.stage(session: session, sleep: { _ in await Task.yield() })
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)

    try await loseSystemAudio(session, on: stage, fixture, waitForLoss: false)
    try await eventually {
        let lost = await stage.systemAudioIsLost(fixture.id)
        return session.restarts.value.count == 5 && !lost
    }
    #expect(session.restarts.value.count == 5)
    let backoffRetries = try await fixture.events(fixture.id).filter { $0.event == "retried" }.dropFirst(2)
    #expect(backoffRetries.count == 3)
    let backoffMeta = try backoffRetries.map { try metadata($0) }
    #expect(backoffMeta.allSatisfy { $0.source == "system_audio" && $0.previousErrorClass == "system_audio_lost" })
    #expect(backoffMeta.map(\.attemptNumber) == [1, 2, 3])
    #expect(backoffMeta.map(\.backoffMS) == [5, 10, 15])

    // Restored: the next system fault restarts inline again.
    session.emit(.transient(.systemAudio, reason: "device lost again"))
    try await eventually { session.restarts.value.count == 6 }
    #expect(try await fixture.events(fixture.id).filter { $0.event == "retried" }.count == 6)

    #expect(try await stage.stop(meetingID: fixture.id) == .captured)
    let meta = try await metadata(fixture.events(fixture.id).last)
    #expect(meta.systemAudioRestoredAt == ISO8601UTC.string(from: fixture.clock.value))
    #expect(meta.systemAudioLossCount == 1)
}

@Test func losingSystemAudioWithNoMicrophoneFailsAsAllSourcesLost() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording(micIncluded: false)
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    try await loseSystemAudio(session, on: stage, fixture)
    try await eventually { try await fixture.meeting(fixture.id).state == "capture_failed" }

    #expect(session.stopCount.value == 1)
    let meta = try await metadata(fixture.events(fixture.id).last)
    #expect(meta.errorClass == "all_sources_lost")
    #expect(meta.systemAudioLossCount == 1)
}

@Test func theMicrophoneCapWhileSystemAudioIsLostFailsAsAllSourcesLost() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    try await loseSystemAudio(session, on: stage, fixture)
    session.emit(.transient(.microphone, reason: "engine stopped"))
    session.emit(.transient(.microphone, reason: "engine stopped"))
    session.emit(.transient(.microphone, reason: "engine stopped"))
    try await eventually { try await fixture.meeting(fixture.id).state == "capture_failed" }

    #expect(session.stopCount.value == 1)
    let meta = try await metadata(fixture.events(fixture.id).last)
    #expect(meta.errorClass == "all_sources_lost")
    #expect(meta.source == "microphone")
    #expect(meta.systemAudioLossCount == 1)
}

@Test func aMicrophoneRevocationWhileSystemAudioIsLostStillFailsTheCapture() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    try await loseSystemAudio(session, on: stage, fixture)
    session.emit(.permissionRevoked(.microphone))
    try await eventually { try await fixture.meeting(fixture.id).state == "capture_failed" }

    #expect(session.stopCount.value == 1)
    let meta = try await metadata(fixture.events(fixture.id).last)
    #expect(meta.errorClass == "permission_revoked_midstream")
    #expect(meta.systemAudioLossCount == 1)
    try await eventually { fixture.notifier.captureFailures.value.count == 1 }
}
