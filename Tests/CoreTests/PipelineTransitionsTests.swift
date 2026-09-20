import Core
import Testing

/// The pairs the three real `StageRunner.run` callers use today: transcribe
/// completes into its own active state, summarize completes into `persisting`,
/// and persist runs under `persisting`.
@Test func theRealCallersPairsAreInTheTable() throws {
    let transcribe = try #require(PipelineTransitions.allowedTargets(stage: .transcribe, activeState: .transcribing))
    #expect(transcribe.contains(.transcribing))
    #expect(transcribe.contains(.transcriptionFailed))

    let summarize = try #require(PipelineTransitions.allowedTargets(stage: .summarize, activeState: .summarizing))
    #expect(summarize == [.persisting, .summarizationFailed])

    let persist = try #require(PipelineTransitions.allowedTargets(stage: .persist, activeState: .persisting))
    #expect(persist == [.published, .persistFailed])
}

/// The table is keyed by the pair `run` receives, so a stage run under another
/// stage's active state has no entry, and a stage's own active state is not a
/// target it may return to unless its entry says so.
@Test func theTableIsKeyedByStageAsWellAsState() throws {
    #expect(PipelineTransitions.allowedTargets(stage: .persist, activeState: .summarizing) == nil)
    #expect(PipelineTransitions.allowedTargets(stage: .summarize, activeState: .persisting) == nil)

    let persist = try #require(PipelineTransitions.allowedTargets(stage: .persist, activeState: .persisting))
    let summarize = try #require(PipelineTransitions.allowedTargets(stage: .summarize, activeState: .summarizing))
    #expect(!persist.contains(.persisting))
    #expect(!summarize.contains(.summarizing))
    #expect(!summarize.contains(.published))
}

@Test func theReviewAndNotifyEntriesFollowDecision12() {
    #expect(PipelineTransitions.allowedTargets(stage: .reviewDiarization, activeState: .reviewingDiarization) == [.awaitingAttribution])
    #expect(PipelineTransitions.allowedTargets(stage: .notify, activeState: .published) == [.awaitingVerification])
}

@Test func theAttributeEntryLeadsOnlyToSummarizing() {
    #expect(PipelineTransitions.allowedTargets(stage: .attribute, activeState: .attributing) == [.summarizing])
}

@Test func aPairWithNoEntryIsNil() {
    #expect(PipelineTransitions.allowedTargets(stage: .transcribe, activeState: .summarizing) == nil)
    #expect(PipelineTransitions.allowedTargets(stage: .capture, activeState: .recording) == nil)
    #expect(PipelineTransitions.allowedTargets(stage: .attribute, activeState: .summarizing) == nil)
}
