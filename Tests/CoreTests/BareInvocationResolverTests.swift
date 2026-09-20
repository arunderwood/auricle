import Core
import Foundation
import Testing

private func summary(id: String, state: String, referenceTimestamp: String = "1970-01-01T00:00:00Z") -> PendingMeetingSummary {
    PendingMeetingSummary(id: id, state: state, referenceTimestamp: referenceTimestamp)
}

@Test func recordingTakesPriorityOverEveryOtherState() {
    let pending = [
        summary(id: "AWAITING-ATTR", state: "awaiting_attribution"),
        summary(id: "RECORDING-ID", state: "recording"),
        summary(id: "AWAITING-VERIFY", state: "awaiting_verification"),
    ]

    guard case let .recording(id, _) = BareInvocationResolver.resolve(pending: pending) else {
        Issue.record("Expected .recording")
        return
    }
    #expect(id == "RECORDING-ID")
}

@Test func awaitingAttributionWinsWhenNothingIsRecording() {
    let pending = [
        summary(id: "AWAITING-VERIFY", state: "awaiting_verification"),
        summary(id: "AWAITING-ATTR", state: "awaiting_attribution"),
    ]

    #expect(BareInvocationResolver.resolve(pending: pending) == .awaitingAttribution(id: "AWAITING-ATTR"))
}

@Test func awaitingVerificationIsLastBeforeNothingInFlight() {
    let pending = [summary(id: "AWAITING-VERIFY", state: "awaiting_verification")]

    #expect(BareInvocationResolver.resolve(pending: pending) == .awaitingVerification(id: "AWAITING-VERIFY"))
}

@Test func emptyPendingListIsNothingInFlight() {
    #expect(BareInvocationResolver.resolve(pending: []) == .nothingInFlight)
}

@Test func elapsedParsesAWholeSecondTimestamp() {
    let now = Date(timeIntervalSince1970: 862) // 14m 22s later

    let elapsed = BareInvocationResolver.elapsed(since: "1970-01-01T00:00:00Z", now: now)

    #expect(elapsed == "14m 22s")
}

@Test func elapsedParsesAFractionalSecondTimestamp() {
    let now = Date(timeIntervalSince1970: 65) // 64.25s after the 0.75s-fractional start

    let elapsed = BareInvocationResolver.elapsed(since: "1970-01-01T00:00:00.750Z", now: now)

    #expect(elapsed == "1m 4s")
}

@Test func elapsedIncludesHoursOnceAnHourHasPassed() {
    let now = Date(timeIntervalSince1970: 3725) // 1h 2m 5s later

    let elapsed = BareInvocationResolver.elapsed(since: "1970-01-01T00:00:00Z", now: now)

    #expect(elapsed == "1h 2m 5s")
}

@Test func elapsedFallsBackToAPlaceholderForAnUnparsableTimestamp() {
    let elapsed = BareInvocationResolver.elapsed(since: "not-a-timestamp", now: Date())

    #expect(elapsed == "unknown duration")
}

// MARK: - Hints carry the selected meeting's id

@Test func awaitingAttributionNamesTheNewestMeetingByReferenceTimestamp() {
    let pending = [
        summary(id: "01OLDER", state: "awaiting_attribution", referenceTimestamp: "2026-01-01T09:00:00Z"),
        summary(id: "01NEWER", state: "awaiting_attribution", referenceTimestamp: "2026-01-02T09:00:00Z"),
        summary(id: "01MIDDLE", state: "awaiting_attribution", referenceTimestamp: "2026-01-01T12:00:00Z"),
    ]

    #expect(BareInvocationResolver.resolve(pending: pending) == .awaitingAttribution(id: "01NEWER"))
}

@Test func awaitingVerificationNamesTheNewestMeetingByReferenceTimestamp() {
    let pending = [
        summary(id: "01NEWER", state: "awaiting_verification", referenceTimestamp: "2026-03-01T09:00:00Z"),
        summary(id: "01OLDER", state: "awaiting_verification", referenceTimestamp: "2026-02-01T09:00:00Z"),
    ]

    #expect(BareInvocationResolver.resolve(pending: pending) == .awaitingVerification(id: "01NEWER"))
}

@Test func recordingNamesTheNewestRecordingWhenSeveralAreStranded() {
    let pending = [
        summary(id: "01STRANDED", state: "recording", referenceTimestamp: "2026-01-01T09:00:00Z"),
        summary(id: "01CURRENT", state: "recording", referenceTimestamp: "2026-01-05T09:00:00Z"),
    ]

    guard case let .recording(id, _) = BareInvocationResolver.resolve(pending: pending) else {
        Issue.record("Expected .recording")
        return
    }
    #expect(id == "01CURRENT")
}

@Test func equalTimestampsBreakTheTieByTheLargerID() {
    let pending = [
        summary(id: "01AAAA", state: "awaiting_attribution", referenceTimestamp: "2026-01-01T09:00:00Z"),
        summary(id: "01CCCC", state: "awaiting_attribution", referenceTimestamp: "2026-01-01T09:00:00Z"),
        summary(id: "01BBBB", state: "awaiting_attribution", referenceTimestamp: "2026-01-01T09:00:00Z"),
    ]

    #expect(BareInvocationResolver.resolve(pending: pending) == .awaitingAttribution(id: "01CCCC"))
}

/// As text, `...00Z` sorts after `...00.398Z`, though it is the earlier instant.
@Test func timestampsAreComparedAsInstantsNotAsText() {
    let pending = [
        summary(id: "01WHOLE", state: "awaiting_attribution", referenceTimestamp: "2026-01-01T09:00:00Z"),
        summary(id: "01FRACTIONAL", state: "awaiting_attribution", referenceTimestamp: "2026-01-01T09:00:00.398Z"),
    ]

    #expect(BareInvocationResolver.resolve(pending: pending) == .awaitingAttribution(id: "01FRACTIONAL"))
}

/// An unparseable timestamp is treated as the oldest, and the pick does not
/// depend on the order the meetings arrive in.
@Test func anUnparseableTimestampNeverBeatsAParseableOne() {
    let unparseable = summary(id: "01ZZZZ", state: "awaiting_attribution", referenceTimestamp: "not a timestamp")
    let early = summary(id: "01AAAA", state: "awaiting_attribution", referenceTimestamp: "2026-01-01T09:00:00Z")
    let late = summary(id: "01BBBB", state: "awaiting_attribution", referenceTimestamp: "2026-01-02T09:00:00.398Z")

    for pending in [[unparseable, early, late], [late, unparseable, early], [early, late, unparseable], [late, early, unparseable]] {
        #expect(BareInvocationResolver.resolve(pending: pending) == .awaitingAttribution(id: "01BBBB"))
    }
    #expect(BareInvocationResolver.resolve(pending: [unparseable, early]) == .awaitingAttribution(id: "01AAAA"))
}

// MARK: - Every pending state has a line

private let meetingID = "01MEETING"
private let clock = Date(timeIntervalSince1970: 65)

/// The states the bare command reports, in the order it prefers them, each with
/// the line it prints for a meeting `01MEETING` recording since the epoch.
private let reportedStates: [(state: PipelineState, message: String)] = [
    (.recording, "Recording 01MEETING — 1m 5s"),
    (.awaitingAttribution, "Last meeting awaiting attribution: auricle attribute 01MEETING"),
    (.awaitingVerification, "Last meeting awaiting your review: auricle keep 01MEETING"),
    (.captureFailed, "Capture failed for 01MEETING — after investigating, retry: auricle run 01MEETING --force"),
    (.transcriptionFailed, "Transcription failed for 01MEETING — after investigating, retry: auricle run 01MEETING --force"),
    (.summarizationFailed, "Summarization failed for 01MEETING — resume: auricle run 01MEETING"),
    (.persistFailed, "Writing the vault note failed for 01MEETING — resume: auricle run 01MEETING"),
    (.publishedPartial, "Published 01MEETING with placeholder speaker names and no summary — fix it in Obsidian, or: auricle run 01MEETING --reattribute"),
    (.captured, "Captured 01MEETING — transcription not started"),
    (.transcribing, "Transcribing 01MEETING"),
    (.reviewingDiarization, "Reviewing speaker labels for 01MEETING"),
    (.attributing, "Attributing 01MEETING — waiting on you"),
    (.summarizing, "Summarizing 01MEETING"),
    (.persisting, "Writing the vault note for 01MEETING"),
    (.published, "Published 01MEETING — review notification pending"),
]

/// `silent` is a benign halt and the rest are terminal, so none is in flight.
private let unreportedStates: [PipelineState] = [.silent] + PipelineState.terminal

@Test func everyPipelineStateIsEitherReportedOrNamedAsNotInFlight() {
    let covered = Set(reportedStates.map(\.state)).union(unreportedStates)

    #expect(covered == Set(PipelineState.allCases))
    #expect(reportedStates.count + unreportedStates.count == PipelineState.allCases.count)
}

@Test(arguments: reportedStates)
func eachReportedStatePrintsItsOwnLine(state: PipelineState, message: String) {
    let pending = [summary(id: meetingID, state: state.rawValue)]

    #expect(BareInvocationResolver.resolve(pending: pending, now: clock).message == message)
}

@Test(arguments: unreportedStates)
func aStateThatIsNotInFlightFallsThroughToNothingInFlight(state: PipelineState) {
    let pending = [summary(id: meetingID, state: state.rawValue)]

    #expect(BareInvocationResolver.resolve(pending: pending, now: clock) == .nothingInFlight)
}

@Test func aStateNameThePipelineDoesNotKnowIsNotReported() {
    let pending = [summary(id: meetingID, state: "from_a_newer_schema")]

    #expect(BareInvocationResolver.resolve(pending: pending, now: clock) == .nothingInFlight)
}

@Test func nothingInFlightPrintsItsFixedLine() {
    #expect(BareInvocationStatus.nothingInFlight.message == "Nothing in flight.")
}

// MARK: - Priority across states

/// Dropping the state that was reported each time must reveal the next one down,
/// however the meetings arrive: that pins the whole order, not just neighbours.
@Test func statesAreReportedInPriorityOrder() {
    let pending = reportedStates.map { summary(id: "01-\($0.state.rawValue)", state: $0.state.rawValue) }

    for (index, expected) in reportedStates.enumerated() {
        let remaining = pending.dropFirst(index)
        for arrangement in [Array(remaining), Array(remaining.reversed())] {
            let message = BareInvocationResolver.resolve(pending: arrangement, now: clock).message
            #expect(message.contains("01-\(expected.state.rawValue)"), "expected \(expected.state) to lead")
        }
    }
}

@Test func aFailureOutranksAMeetingThatIsStillMoving() {
    let pending = [
        summary(id: "01MOVING", state: "summarizing"),
        summary(id: "01FAILED", state: "persist_failed"),
    ]

    #expect(BareInvocationResolver.resolve(pending: pending) == .persistFailed(id: "01FAILED"))
}

@Test func failuresAreReportedInPipelineOrder() {
    let pending = [
        summary(id: "01PERSIST", state: "persist_failed", referenceTimestamp: "2026-05-04T09:00:00Z"),
        summary(id: "01CAPTURE", state: "capture_failed", referenceTimestamp: "2026-05-01T09:00:00Z"),
        summary(id: "01SUMMARY", state: "summarization_failed", referenceTimestamp: "2026-05-03T09:00:00Z"),
    ]

    #expect(BareInvocationResolver.resolve(pending: pending) == .captureFailed(id: "01CAPTURE"))
}

// MARK: - Newest per state, for the states added beyond the documented three

@Test(arguments: reportedStates.map(\.state).dropFirst(3))
func theNewestMeetingWinsWithinAnyState(state: PipelineState) {
    let pending = [
        summary(id: "01OLDER", state: state.rawValue, referenceTimestamp: "2026-01-01T09:00:00Z"),
        summary(id: "01NEWER", state: state.rawValue, referenceTimestamp: "2026-01-02T09:00:00Z"),
        summary(id: "01MIDDLE", state: state.rawValue, referenceTimestamp: "2026-01-01T12:00:00Z"),
    ]

    #expect(BareInvocationResolver.resolve(pending: pending).message.contains("01NEWER"))
}

@Test(arguments: reportedStates.map(\.state).dropFirst(3))
func equalTimestampsBreakTheTieByTheLargerIDInAnyState(state: PipelineState) {
    let pending = [
        summary(id: "01AAAA", state: state.rawValue, referenceTimestamp: "2026-01-01T09:00:00Z"),
        summary(id: "01CCCC", state: state.rawValue, referenceTimestamp: "2026-01-01T09:00:00Z"),
        summary(id: "01BBBB", state: state.rawValue, referenceTimestamp: "2026-01-01T09:00:00Z"),
    ]

    #expect(BareInvocationResolver.resolve(pending: pending).message.contains("01CCCC"))
}
