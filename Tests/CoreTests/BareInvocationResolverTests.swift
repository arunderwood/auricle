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

@Test func theMessageRendersEachStatusWithTheMeetingsOwnID() {
    #expect(BareInvocationStatus.recording(id: "01REC", elapsed: "1m 4s").message == "Recording 01REC — 1m 4s")
    #expect(BareInvocationStatus.awaitingAttribution(id: "01ATTR").message == "Last meeting awaiting attribution: auricle attribute 01ATTR")
    #expect(BareInvocationStatus.awaitingVerification(id: "01KEEP").message == "Last meeting awaiting your review: auricle keep 01KEEP")
    #expect(BareInvocationStatus.nothingInFlight.message == "Nothing in flight.")
}
