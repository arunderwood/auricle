import Core
import Foundation
import Orchestrator
import Pipeline
import State
import Telemetry
import Testing

private struct UnreadableConfig: Error {}

/// A launcher over the fixture's store and scripted workers, reading
/// whatever config `loadConfig` returns, the fixture's vault by default.
private func makeLauncher(
    _ fixture: PipelineFixture,
    workers: ScriptedLauncher,
    loadConfig: (@Sendable () throws -> Config)? = nil,
) -> CapturePipelineLauncher {
    let vaultPath = fixture.vaultPath
    return CapturePipelineLauncher(
        stateStore: fixture.store,
        launcher: workers,
        notifier: fixture.notifier,
        loadConfig: loadConfig ?? { Config(vaultPath: vaultPath) },
    )
}

/// The capture `completed` event a meeting landed `captured` with.
private func recordCaptureCompleted(_ meetingID: MeetingID, metadataJSON: String?, in store: StateStore) async throws {
    try await StageEventLogger(stateStore: store).record(event: StageEventRecord(
        meetingID: meetingID,
        stage: .capture,
        kind: .completed,
        occurredAt: "2026-04-28T13:00:00Z",
        targetState: .captured,
        metadataJSON: metadataJSON,
    ))
}

/// Another `captured` meeting in the fixture's store. Its id never reaches
/// the scripted workers unless the launcher runs it, and they then drive
/// the fixture's own meeting, so a run of it shows as extra launches.
private func insertCapturedMeeting(in store: StateStore) async throws -> MeetingID {
    let meetingID = MeetingID.generate()
    try await store.insertMeeting(Meeting(
        id: meetingID.rawValue, state: PipelineState.captured.rawValue,
        createdAt: "2026-04-28T09:00:00Z", updatedAt: "2026-04-28T09:00:00Z",
    ))
    return meetingID
}

private let stoppedCapture = #"{"exact_zero_seconds":0,"mic_included":true,"tap_rebuilds":0}"#
private let recoveredCapture = #"{"reason":"recovered_after_interruption"}"#
private let importedCapture = #"{"audio_duration_seconds":3,"source_format":"wav"}"#

// MARK: - After a stop

@Test func aCapturedMeetingRunsToAwaitingAttribution() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    let workers = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await makeLauncher(fixture, workers: workers).runAfterCapture(fixture.meetingID)

    #expect(CapturePipelineLauncher.runTarget == .reviewDiarization)
    #expect(result?.exitCode == WorkerExitCode.success)
    #expect(workers.stages == [.transcribe, .reviewDiarization])
    #expect(try await fixture.meeting().state == "awaiting_attribution")
}

@Test func anUnreadableConfigLeavesTheMeetingCapturedForTheNextLaunch() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try await recordCaptureCompleted(fixture.meetingID, metadataJSON: stoppedCapture, in: fixture.store)
    let workers = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await makeLauncher(fixture, workers: workers, loadConfig: { throw UnreadableConfig() }).runAfterCapture(fixture.meetingID)

    #expect(result == nil)
    #expect(workers.stages.isEmpty)
    #expect(try await fixture.meeting().state == "captured")

    let resumed = await makeLauncher(fixture, workers: workers).resumeStrandedCaptures()

    #expect(resumed == [fixture.meetingID])
    #expect(try await fixture.meeting().state == "awaiting_attribution")
}

// MARK: - At launch

@Test func aStrandedStoppedCaptureIsResumed() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try await recordCaptureCompleted(fixture.meetingID, metadataJSON: stoppedCapture, in: fixture.store)
    let workers = ScriptedLauncher(fixture.simulatedWorkers())

    let resumed = await makeLauncher(fixture, workers: workers).resumeStrandedCaptures()

    #expect(resumed == [fixture.meetingID])
    #expect(workers.stages == [.transcribe, .reviewDiarization])
    #expect(try await fixture.meeting().state == "awaiting_attribution")
}

@Test(arguments: [recoveredCapture, importedCapture, nil])
func aCapturedMeetingNoStopLandedWaitsForTheUser(metadataJSON: String?) async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try await recordCaptureCompleted(fixture.meetingID, metadataJSON: metadataJSON, in: fixture.store)
    let workers = ScriptedLauncher(fixture.simulatedWorkers())

    let resumed = await makeLauncher(fixture, workers: workers).resumeStrandedCaptures()

    #expect(resumed.isEmpty)
    #expect(workers.stages.isEmpty)
    #expect(try await fixture.meeting().state == "captured")
}

@Test func aCapturedMeetingWithNoCaptureEventWaitsForTheUser() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    let workers = ScriptedLauncher(fixture.simulatedWorkers())

    #expect(await makeLauncher(fixture, workers: workers).resumeStrandedCaptures().isEmpty)
    #expect(workers.stages.isEmpty)
}

/// Only the latest capture `completed` event counts: a stopped capture that
/// launch recovery later relabelled is a recovered one.
@Test func theLatestCaptureEventDecides() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try await recordCaptureCompleted(fixture.meetingID, metadataJSON: stoppedCapture, in: fixture.store)
    try await recordCaptureCompleted(fixture.meetingID, metadataJSON: recoveredCapture, in: fixture.store)
    let workers = ScriptedLauncher(fixture.simulatedWorkers())

    #expect(await makeLauncher(fixture, workers: workers).resumeStrandedCaptures().isEmpty)
}

@Test func aMeetingThatCannotBeReadIsSkippedAndTheRestStillRun() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try await recordCaptureCompleted(fixture.meetingID, metadataJSON: stoppedCapture, in: fixture.store)
    let unreadable = try await insertCapturedMeeting(in: fixture.store)
    try await recordCaptureCompleted(unreadable, metadataJSON: "not json", in: fixture.store)
    let recovered = try await insertCapturedMeeting(in: fixture.store)
    try await recordCaptureCompleted(recovered, metadataJSON: recoveredCapture, in: fixture.store)
    let workers = ScriptedLauncher(fixture.simulatedWorkers())

    let resumed = await makeLauncher(fixture, workers: workers).resumeStrandedCaptures()

    #expect(resumed == [fixture.meetingID])
    #expect(workers.stages == [.transcribe, .reviewDiarization])
    #expect(try await fixture.store.fetchMeeting(id: unreadable.rawValue)?.state == "captured")
    #expect(try await fixture.store.fetchMeeting(id: recovered.rawValue)?.state == "captured")
}
