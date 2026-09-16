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

    #expect(BareInvocationResolver.resolve(pending: pending) == .awaitingAttribution)
}

@Test func awaitingVerificationIsLastBeforeNothingInFlight() {
    let pending = [summary(id: "AWAITING-VERIFY", state: "awaiting_verification")]

    #expect(BareInvocationResolver.resolve(pending: pending) == .awaitingVerification)
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
