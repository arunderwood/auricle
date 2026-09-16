import Orchestrator
import Testing

@Test func pipelineStageRawValuesMatchCanonicalSpellings() {
    let expected: [PipelineStage: String] = [
        .capture: "capture",
        .transcribe: "transcribe",
        .reviewDiarization: "review-diarization",
        .attribute: "attribute",
        .summarize: "summarize",
        .persist: "persist",
        .notify: "notify",
        .verify: "verify",
        .discard: "discard",
    ]

    #expect(PipelineStage.allCases.count == 9)
    #expect(expected.count == 9)
    for stage in PipelineStage.allCases {
        #expect(stage.rawValue == expected[stage])
    }
}
