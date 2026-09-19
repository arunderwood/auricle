import Core
@testable import Orchestrator
import Testing

@Test(arguments: [
    (PipelineState.transcribing, PipelineStage.transcribe),
    (.reviewingDiarization, .reviewDiarization),
    (.summarizing, .summarize),
    (.persisting, .persist),
    (.published, .notify),
])
func eachBudgetedActiveStateMapsToTheStageItIsWaitingOn(state: PipelineState, stage: PipelineStage) {
    #expect(ActiveStageInFlight.stage(for: state) == stage)
}

@Test func statesWithNoStageInFlightMapToNil() {
    #expect(ActiveStageInFlight.stage(for: .attributing) == nil)
    #expect(ActiveStageInFlight.stage(for: .persistFailed) == nil)
    #expect(ActiveStageInFlight.stage(for: .verified) == nil)
}
