import ArgumentParser
import Core
@testable import Orchestrator
import Testing

private let meetingID = "01HJK3PQXY7N8M3FT4QHNWVZRP"

private func plan(_ options: RunOptions, from state: PipelineState) throws -> RunPlan {
    try RunPlan.make(options: options, state: state).get()
}

// MARK: - Flag conflicts

@Test(arguments: [
    ["--from", "transcribe", "--only", "summarize"],
    ["--to", "summarize", "--only", "summarize"],
    ["--publish-anyway", "--from", "attribute"],
    ["--publish-anyway", "--only", "attribute"],
    ["--publish-anyway", "--reattribute"],
    ["--reattribute", "--from", "summarize"],
    ["--reattribute", "--only", "summarize"],
    ["--from", "persist", "--to", "summarize"],
    ["--from", "nonsense"],
])
func flagConflictsAreRejectedAtParseTimeWithExitOne(flags: [String]) {
    do {
        _ = try RunArguments.parse([meetingID] + flags)
        Issue.record("expected \(flags) to be rejected")
    } catch {
        #expect(RunArguments.exitCode(for: error) == ExitCode.failure)
    }
}

@Test(arguments: [
    ["--from", "transcribe", "--to", "summarize"],
    ["--only", "summarize"],
    ["--publish-anyway", "--from", "summarize"],
    ["--force", "--reattribute"],
    ["--force", "--publish-anyway"],
    ["--reattribute"],
])
func compatibleFlagsParse(flags: [String]) throws {
    _ = try RunArguments.parse([meetingID] + flags)
}

// MARK: - Start stage from state

@Test(arguments: [
    (PipelineState.captured, RunStage.transcribe),
    (.transcribing, .transcribe),
    (.reviewingDiarization, .reviewDiarization),
    (.awaitingAttribution, .attribute),
    (.summarizing, .summarize),
    (.summarizationFailed, .summarize),
    (.publishedPartial, .summarize),
    (.persisting, .persist),
    (.persistFailed, .persist),
    (.published, .notify),
])
func aBareRunResumesAtTheStageTheStateNeeds(state: PipelineState, start: RunStage) throws {
    let stages = try plan(RunOptions(), from: state).stages

    #expect(stages.first == start)
    #expect(stages.last == .notify)
}

@Test func aBareRunFromCapturedDrivesEveryStageInOrder() throws {
    #expect(try plan(RunOptions(), from: .captured).stages == RunStage.allCases)
}

@Test func persistFailedResumesAtPersistAndNotifyOnly() throws {
    #expect(try plan(RunOptions(), from: .persistFailed).stages == [.persist, .notify])
}

@Test func awaitingVerificationHasNothingToRun() throws {
    #expect(try plan(RunOptions(), from: .awaitingVerification).stages.isEmpty)
}

// MARK: - Subsets

@Test func fromAndToBoundTheStages() throws {
    let options = RunOptions(from: .transcribe, to: .summarize)

    #expect(try plan(options, from: .captured).stages == [.transcribe, .reviewDiarization, .attribute, .summarize])
}

@Test func onlyRunsOneStage() throws {
    #expect(try plan(RunOptions(only: .summarize), from: .summarizationFailed).stages == [.summarize])
}

@Test func toBeforeTheResolvedStartIsAPlanErrorNamingBothStages() throws {
    let result = RunPlan.make(options: RunOptions(to: .transcribe), state: .awaitingAttribution)

    #expect(result == .failure(.toPrecedesStart(to: .transcribe, start: .attribute)))
    let message = try #require(result.failure?.message)
    #expect(message.contains("transcribe") && message.contains("attribute"))
}

@Test(arguments: [PipelineState.transcriptionFailed, .captureFailed])
func anExplicitFromOrOnlyDoesNotLiftThePermanentFailureRefusal(state: PipelineState) {
    #expect(RunPlan.make(options: RunOptions(from: .summarize), state: state) == .failure(.permanentFailure(state)))
    #expect(RunPlan.make(options: RunOptions(only: .summarize), state: state) == .failure(.permanentFailure(state)))
    #expect((try? RunPlan.make(options: RunOptions(force: true, from: .transcribe), state: state).get())?.stages.first == .transcribe)
}

@Test func anExplicitFromBeatsTheStateDerivedStart() throws {
    #expect(try plan(RunOptions(from: .summarize), from: .persistFailed).stages == [.summarize, .persist, .notify])
}

// MARK: - Impossible starts

@Test(arguments: [
    (RunStage.notify, PipelineState.awaitingAttribution),
    (.persist, .captured),
    (.summarize, .awaitingAttribution),
    (.attribute, .captured),
    (.reviewDiarization, .published),
    (.notify, .awaitingVerification),
])
func anExplicitStartTheMeetingHasNotReachedIsRefusedNamingBoth(stage: RunStage, state: PipelineState) throws {
    for options in [RunOptions(from: stage), RunOptions(only: stage)] {
        let refusal = try #require(RunPlan.make(options: options, state: state).failure)

        #expect(refusal == .cannotStart(stage: stage, state: state))
        #expect(refusal.message.contains(stage.rawValue) && refusal.message.contains(state.rawValue))
    }
}

@Test(arguments: [PipelineState.captureFailed, .transcriptionFailed])
func forceDoesNotMakeALaterStageStartableFromAFailedCapture(state: PipelineState) {
    let result = RunPlan.make(options: RunOptions(force: true, from: .summarize), state: state)

    #expect(result == .failure(.cannotStart(stage: .summarize, state: state)))
}

@Test(arguments: PipelineState.allCases.filter { ![.recording, .silent, .verified, .discarded, .retentionExpired].contains($0) })
func transcribeStartsFromEveryRunnableState(state: PipelineState) throws {
    #expect(try plan(RunOptions(force: true), from: state).stages == RunStage.allCases)
}

@Test(arguments: PipelineState.allCases)
func theStageAStateResumesAtCanStartFromThatState(state: PipelineState) {
    guard let stage = try? plan(RunOptions(), from: state).stages.first else { return }

    #expect(stage.entryStates.contains(state))
}

// MARK: - Refusals and force

@Test(arguments: [PipelineState.verified, .discarded, .silent, .recording, .retentionExpired])
func meetingsNoRunCanTouchAreRefusedEvenWithForce(state: PipelineState) {
    #expect(RunPlan.make(options: RunOptions(force: true), state: state) == .failure(.notRunnable(state)))
    #expect(RunPlan.make(options: RunOptions(), state: state) == .failure(.notRunnable(state)))
}

@Test(arguments: [PipelineState.captureFailed, .transcriptionFailed])
func aPermanentFailureIsRefusedNamingForceAndForceRunsFromTranscribe(state: PipelineState) throws {
    let refusal = try #require(RunPlan.make(options: RunOptions(), state: state).failure)

    #expect(refusal == .permanentFailure(state))
    #expect(refusal.message.contains("--force"))
    #expect(try plan(RunOptions(force: true), from: state).stages == RunStage.allCases)
}

@Test(arguments: [PipelineState.awaitingVerification, .published, .publishedPartial])
func reattributeRunsFromAttributeOnAPublishedMeeting(state: PipelineState) throws {
    let stages = try plan(RunOptions(reattribute: true), from: state).stages

    #expect(stages == [.attribute, .summarize, .persist, .notify])
}

@Test func reattributeOnAnUnpublishedMeetingIsRefused() {
    #expect(RunPlan.make(options: RunOptions(reattribute: true), state: .captured) == .failure(.notPublished(.captured)))
}

@Test func forceOnAPublishedMeetingRunsEverythingFromTranscribe() throws {
    #expect(try plan(RunOptions(force: true), from: .awaitingVerification).stages == RunStage.allCases)
}

@Test func publishAnywayTravelsWithThePlan() throws {
    #expect(try plan(RunOptions(publishAnyway: true), from: .awaitingAttribution).publishAnyway)
    #expect(try !plan(RunOptions(), from: .awaitingAttribution).publishAnyway)
}

// MARK: - Worker coverage

@Test func everySubprocessStageTheVerbDrivesHasAWorkerCaseAndTheRestRunInProcess() {
    var subprocessStages: Set<PipelineStage> = []
    for stage in RunStage.allCases {
        switch stage.execution {
        case let .subprocess(kind):
            #expect(kind.stage == stage.pipelineStage)
            subprocessStages.insert(stage.pipelineStage)
        case .inProcess:
            #expect(InternalStageKind(stage: stage.pipelineStage) == nil)
        }
    }

    #expect(subprocessStages == Set(InternalStageKind.allCases.map(\.stage)))
    #expect(subprocessStages == [.transcribe, .reviewDiarization, .summarize])
    #expect(RunStage.allCases.filter { $0.execution == .inProcess } == [.attribute, .persist, .notify])
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self {
            error
        } else {
            nil
        }
    }
}
