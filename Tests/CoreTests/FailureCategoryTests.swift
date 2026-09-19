import Core
import Testing

@Test func failureCategoryRawValuesAreTheSnakeCaseSpellings() {
    #expect(FailureCategory.transient.rawValue == "transient")
    #expect(FailureCategory.permanent.rawValue == "permanent")
    #expect(FailureCategory.userActionable.rawValue == "user_actionable")
    #expect(FailureCategory.benignTerminal.rawValue == "benign_terminal")
    #expect(FailureCategory.allCases.count == 4)
}

/// Pinned per state, not derived, so a state moved between categories is a
/// deliberate edit of this table (architecture.md Decision 4.1).
@Test func everyStateMapsToItsDecision41Category() {
    let expected: [PipelineState: FailureCategory?] = [
        .recording: nil,
        .captured: nil,
        .transcribing: nil,
        .reviewingDiarization: nil,
        .awaitingAttribution: .userActionable,
        .attributing: nil,
        .summarizing: nil,
        .persisting: nil,
        .published: nil,
        .awaitingVerification: .userActionable,
        .verified: nil,
        .retentionExpired: nil,
        .silent: .benignTerminal,
        .discarded: nil,
        .captureFailed: .permanent,
        .transcriptionFailed: .permanent,
        .summarizationFailed: .transient,
        .persistFailed: .transient,
        .publishedPartial: .userActionable,
    ]

    #expect(expected.count == PipelineState.allCases.count)
    for state in PipelineState.allCases {
        #expect(state.failureCategory == expected[state], "\(state)")
    }
}

@Test func onlyTheFourFailedStatesReportIsFailed() {
    let failed = Set(PipelineState.allCases.filter(\.isFailed))

    #expect(failed == [.captureFailed, .transcriptionFailed, .summarizationFailed, .persistFailed])
    #expect(failed.allSatisfy { $0.rawValue.hasSuffix("_failed") })
    #expect(PipelineState.allCases.filter { $0.rawValue.hasSuffix("_failed") }.count == failed.count)
}

@Test func workerExitCodesAreTheNamedDecision15Values() {
    #expect(WorkerExitCode.success == 0)
    #expect(WorkerExitCode.callerError == 1)
    #expect(WorkerExitCode.stateError == 2)
    #expect(WorkerExitCode.meetingNotFound == 3)
    #expect(WorkerExitCode.usage == 64)
    #expect(WorkerExitCode.retryable == 75)
}
