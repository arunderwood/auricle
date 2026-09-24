import Attribute
import Core
import Foundation
import Orchestrator
import Pipeline
@testable import State
import Testing

// MARK: - Resume

@Test func aBareRunFromCapturedDrivesEveryStageAndLeavesTheMeetingUnverified() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try fixture.plantMapping()
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result == RunResult(exitCode: 0))
    #expect(launcher.stages == [.transcribe, .reviewDiarization, .summarize])
    let meeting = try await fixture.meeting()
    #expect(meeting.state == "awaiting_verification")
    #expect(meeting.verifiedAt == nil)
    let notePath = try #require(meeting.vaultNotePath)
    #expect(notePath.hasPrefix(fixture.vaultPath.appendingPathComponent("Meetings").path))
    #expect(FileManager.default.fileExists(atPath: notePath))
    #expect(fixture.notifier.paths.value == [notePath])
    let stages = try await fixture.events().filter { $0.event == "completed" }.map(\.stage)
    #expect(stages == ["transcribe", "review-diarization", "attribute", "summarize", "persist", "notify"])
}

@Test func aRunFromPersistFailedRerunsPersistAndNotifyOnly() async throws {
    let fixture = try await PipelineFixture(state: .persistFailed)
    defer { fixture.cleanUp() }
    try fixture.plantSummary()
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.stages.isEmpty)
    #expect(try await fixture.meeting().state == "awaiting_verification")
    #expect(try await fixture.events().filter { $0.event == "started" }.map(\.stage) == ["persist", "notify"])
}

@Test func aRunFromSummarizationFailedResumesAtSummarize() async throws {
    let fixture = try await PipelineFixture(state: .summarizationFailed)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.stages == [.summarize])
    #expect(try await fixture.meeting().state == "awaiting_verification")
}

@Test func aFinishedMeetingHasNothingToRun() async throws {
    let fixture = try await PipelineFixture(state: .awaitingVerification)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.stages.isEmpty)
}

// MARK: - Subsets

@Test func toStopsAfterTheNamedStage() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(to: .reviewDiarization), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.stages == [.transcribe, .reviewDiarization])
    #expect(try await fixture.meeting().state == "awaiting_attribution")
}

@Test func onlyRunsTheNamedStageAlone() async throws {
    let fixture = try await PipelineFixture(state: .summarizing)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(only: .summarize), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.stages == [.summarize])
    #expect(try await fixture.meeting().state == "persisting")
}

@Test func fromAndToRunTheRangeAcrossSubprocessAndInProcessStages() async throws {
    let fixture = try await PipelineFixture(state: .awaitingAttribution)
    defer { fixture.cleanUp() }
    try fixture.plantMapping()
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(from: .attribute, to: .summarize), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.stages == [.summarize])
    #expect(try await fixture.meeting().state == "persisting")
}

// MARK: - Refusals

@Test func aMeetingWithoutAMappingStopsBeforeAttributeAndPointsAtTheTwoWaysForward() async throws {
    let fixture = try await PipelineFixture(state: .awaitingAttribution)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == 1)
    let message = try #require(result.message)
    #expect(message.contains("auricle attribute"))
    #expect(message.contains("--publish-anyway"))
    #expect(launcher.stages.isEmpty)
    #expect(try await fixture.meeting().state == "awaiting_attribution")
}

@Test(arguments: [PipelineState.transcriptionFailed, .captureFailed])
func aPermanentFailureIsRefusedNamingForce(state: PipelineState) async throws {
    let fixture = try await PipelineFixture(state: state)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == 1)
    #expect(result.message?.contains("--force") == true)
    #expect(launcher.stages.isEmpty)
    #expect(try await fixture.meeting().state == state.rawValue)
}

@Test func forceRerunsEveryStageFromTranscribeOnAPermanentFailure() async throws {
    let fixture = try await PipelineFixture(state: .transcriptionFailed)
    defer { fixture.cleanUp() }
    try fixture.plantMapping()
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(force: true), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.stages == [.transcribe, .reviewDiarization, .summarize])
    #expect(try await fixture.meeting().state == "awaiting_verification")
}

@Test func aVerifiedMeetingIsRefusedEvenWithForce() async throws {
    let fixture = try await PipelineFixture(state: .verified)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(force: true), launcher: launcher)

    #expect(result.exitCode == 1)
    #expect(launcher.stages.isEmpty)
}

@Test func aRunThatReachesPersistWithoutAVaultRefusesBeforeSpendingAnything() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try fixture.plantMapping()
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.runner(launcher: launcher, vaultPath: .some(nil)).run(meetingID: fixture.meetingID, options: RunOptions())

    #expect(result.exitCode == 1)
    #expect(result.message?.contains("vault_path") == true)
    #expect(launcher.stages.isEmpty)
    #expect(try await fixture.meeting().state == "captured")
}

@Test func theMissingVaultMessageNamesTheConfigFileInUse() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try fixture.plantMapping()
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())
    let runner = PipelineRunner(environment: PipelineRunner.Environment(
        stateStore: fixture.store,
        launcher: launcher,
        notifier: fixture.notifier,
        vaultPath: nil,
        meetingsSubdir: "Meetings",
        configDisplayPath: "/tmp/x/config.toml",
    ))

    let result = await runner.run(meetingID: fixture.meetingID, options: RunOptions())

    #expect(result.message == "vault_path is not set in /tmp/x/config.toml.")
}

@Test func anUnknownMeetingExitsThree() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.runner(launcher: launcher).run(meetingID: MeetingID.generate(), options: RunOptions())

    #expect(result.exitCode == WorkerExitCode.meetingNotFound)
}

// MARK: - Worker failures and retry

@Test func aWorkerFailureStopsTheRunAndReturnsItsExitCode() async throws {
    let fixture = try await PipelineFixture(state: .summarizing)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers(summarizeFails: true))

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == 2)
    #expect(try await fixture.meeting().state == "summarization_failed")
    #expect(fixture.notifier.paths.value.isEmpty)
    #expect(try fixture.meetingsDirectoryFiles().isEmpty)
}

@Test func transcribeIsRetriedOnceInAFreshProcessWhenTheWorkerAsksForIt() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try fixture.plantMapping()
    let queue = Locked<[Int32]>([WorkerExitCode.retryable, 0])
    let launcher = ScriptedLauncher(fixture.simulatedWorkers(transcribeStatus: queue))

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.stages == [.transcribe, .transcribe, .reviewDiarization, .summarize])
    #expect(try await fixture.events().contains { $0.event == "retried" && $0.stage == "transcribe" })
    #expect(try await fixture.meeting().state == "awaiting_verification")
}

@Test func aSecondRetryableFailureStandsAsTheRunsExit() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    let queue = Locked<[Int32]>([WorkerExitCode.retryable, WorkerExitCode.retryable])
    let launcher = ScriptedLauncher(fixture.simulatedWorkers(transcribeStatus: queue))

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == WorkerExitCode.retryable)
    #expect(launcher.stages == [.transcribe, .transcribe])
    #expect(try await fixture.meeting().state == "transcription_failed")
}

// MARK: - publish-anyway

@Test func publishAnywayPublishesWithPlaceholdersAndTheNeedsAttributionTag() async throws {
    let fixture = try await PipelineFixture(state: .awaitingAttribution)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(publishAnyway: true), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.launches.value == [RecordedLaunch(stage: .summarize, publishAnyway: true)])
    let meeting = try await fixture.meeting()
    #expect(meeting.state == "awaiting_verification")
    let note = try String(contentsOfFile: #require(meeting.vaultNotePath), encoding: .utf8)
    #expect(note.contains("auricle/needs-attribution"))
    #expect(!note.contains("auricle/needs-summary"))
}

@Test func publishAnywayWithAFailedSummarizePublishesPartialAndSkipsNotify() async throws {
    let fixture = try await PipelineFixture(state: .awaitingAttribution)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers(summarizeFails: true))

    let result = await fixture.run(RunOptions(publishAnyway: true), launcher: launcher)

    #expect(result.exitCode == 0)
    let meeting = try await fixture.meeting()
    #expect(meeting.state == "published_partial")
    let notePath = try #require(meeting.vaultNotePath)
    #expect(result.lines == [notePath])
    let note = try String(contentsOfFile: notePath, encoding: .utf8)
    #expect(note.contains("auricle/needs-attribution"))
    #expect(note.contains("auricle/needs-summary"))
    #expect(!note.contains("## Action Items"))
    #expect(!note.contains("## Decisions"))
    #expect(fixture.notifier.paths.value.isEmpty)
    #expect(meeting.verifiedAt == nil)
}

@Test func aPublishedPartialMeetingResumesAtSummarize() async throws {
    let fixture = try await PipelineFixture(state: .awaitingAttribution)
    defer { fixture.cleanUp() }
    let failing = ScriptedLauncher(fixture.simulatedWorkers(summarizeFails: true))
    _ = await fixture.run(RunOptions(publishAnyway: true), launcher: failing)
    fixture.rerunInstant.value = "2026-05-16T12:00:00Z"
    let recovering = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(), launcher: recovering)

    #expect(result.exitCode == 0)
    #expect(recovering.stages == [.summarize])
    let meeting = try await fixture.meeting()
    #expect(meeting.state == "awaiting_verification")
    let note = try String(contentsOfFile: #require(meeting.vaultNotePath), encoding: .utf8)
    #expect(note.contains(fixture.summaryText.value))
    #expect(!note.contains("auricle/needs-summary"))
}

// MARK: - reattribute

@Test func reattributeOnAPublishedMeetingWritesARerunSiblingAndLeavesTheRetentionTimerAlone() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    try fixture.plantMapping()
    _ = await fixture.run(RunOptions(), launcher: ScriptedLauncher(fixture.simulatedWorkers()))
    let original = try #require(try await fixture.meeting().vaultNotePath)
    let timer = RetentionTimer(meetingID: fixture.meetingID.rawValue, armedAt: "2026-04-29T09:00:00Z", firesAt: "2026-05-29T09:00:00Z")
    try await fixture.store.insertRetentionTimer(timer)
    fixture.summaryText.value = "A corrected summary."
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(reattribute: true), launcher: launcher)

    #expect(result.exitCode == 0)
    #expect(launcher.stages == [.summarize])
    let meeting = try await fixture.meeting()
    let sibling = try #require(meeting.vaultNotePath)
    #expect(sibling != original)
    #expect(URL(fileURLWithPath: sibling).lastPathComponent.contains("--rerun-2026-05-15"))
    #expect(FileManager.default.fileExists(atPath: original))
    let note = try String(contentsOfFile: sibling, encoding: .utf8)
    #expect(note.contains("supersedes: \"\(URL(fileURLWithPath: original).lastPathComponent)\""))
    #expect(try await fixture.store.fetchRetentionTimer(meetingID: fixture.meetingID.rawValue) == timer)
    #expect(meeting.state == "awaiting_verification")
    #expect(meeting.verifiedAt == nil)
}

// MARK: - Interrupt

@Test func anInterruptDuringSummarizeTerminatesTheWorkerAndFailsTheMeetingWithExit130() async throws {
    let fixture = try await PipelineFixture(state: .summarizing)
    defer { fixture.cleanUp() }
    let entered = Locked(false)
    let launcher = ScriptedLauncher { _, _ in
        entered.value = true
        try await Task.sleep(for: .seconds(60))
        return .exited(0)
    }
    let runner = fixture.runner(launcher: launcher)
    let meetingID = fixture.meetingID
    let task = Task { await runner.run(meetingID: meetingID, options: RunOptions()) }
    while !entered.value {
        try await Task.sleep(for: .milliseconds(5))
    }

    task.cancel()
    let result = await task.value

    #expect(result.exitCode == 130)
    #expect(try await fixture.meeting().state == "summarization_failed")
    let failed = try #require(try await fixture.events().last { $0.event == "failed" })
    #expect(failed.metadataJSON?.contains("cancelled_by_user") == true)
    #expect(try fixture.meetingsDirectoryFiles().isEmpty)
}

@Test func anInterruptAfterSummarizeFinishedLeavesTheMeetingWhereItIs() async throws {
    let fixture = try await PipelineFixture(state: .summarizing)
    defer { fixture.cleanUp() }
    let workers = fixture.simulatedWorkers()
    let launcher = ScriptedLauncher { stage, publishAnyway in
        _ = try await workers(stage, publishAnyway)
        throw CancellationError()
    }

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == 130)
    #expect(try await fixture.meeting().state == "persisting")
}

// MARK: - State guards

@Test(arguments: [
    (RunStage.notify, PipelineState.awaitingAttribution),
    (.persist, .captured),
    (.summarize, .awaitingAttribution),
])
func anOnlyStageTheMeetingHasNotReachedIsRefusedAndWritesNothing(stage: RunStage, state: PipelineState) async throws {
    let fixture = try await PipelineFixture(state: state)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher(fixture.simulatedWorkers())

    let result = await fixture.run(RunOptions(only: stage), launcher: launcher)

    #expect(result.exitCode == 1)
    let message = try #require(result.message)
    #expect(message.contains(stage.rawValue) && message.contains(state.rawValue))
    #expect(launcher.stages.isEmpty)
    #expect(try await fixture.meeting().state == state.rawValue)
    #expect(try await fixture.events().isEmpty)
    #expect(fixture.notifier.paths.value.isEmpty)
}

@Test func aStageThatLeavesTheMeetingWhereTheNextCannotStartStopsTheRun() async throws {
    let fixture = try await PipelineFixture(state: .captured)
    defer { fixture.cleanUp() }
    let launcher = ScriptedLauncher { _, _ in .exited(0) }

    let result = await fixture.run(RunOptions(), launcher: launcher)

    #expect(result.exitCode == 1)
    #expect(try #require(result.message).contains("review-diarization cannot start from state captured"))
    #expect(launcher.stages == [.transcribe])
    #expect(try await fixture.meeting().state == "captured")
}
