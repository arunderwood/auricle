import CalendarInterface
@testable import GoogleCalendarSource
import Testing

private struct FailureExpectation: Sendable, CustomTestStringConvertible {
    let failure: GoogleCalendarFailure
    let calendarError: CalendarError
    let caseName: String

    var testDescription: String {
        caseName
    }
}

private let expectations: [FailureExpectation] = [
    FailureExpectation(failure: .notAuthorized, calendarError: .authorizationExpired, caseName: "notAuthorized"),
    FailureExpectation(failure: .authorizationExpired, calendarError: .authorizationExpired, caseName: "authorizationExpired"),
    FailureExpectation(failure: .authorizationFailed(reason: "any reason"), calendarError: .authorizationExpired, caseName: "authorizationFailed"),
    FailureExpectation(failure: .unreachable, calendarError: .unreachable, caseName: "unreachable"),
    FailureExpectation(failure: .rateLimited, calendarError: .unreachable, caseName: "rateLimited"),
    FailureExpectation(failure: .malformedResponse, calendarError: .unreachable, caseName: "malformedResponse"),
]

@Test(arguments: expectations)
private func aFailureMapsToTheCalendarErrorTheSourceReports(expectation: FailureExpectation) {
    #expect(expectation.failure.calendarError == expectation.calendarError)
}

@Test(arguments: expectations)
private func aFailureIsLoggedByItsFixedCaseName(expectation: FailureExpectation) {
    #expect(expectation.failure.caseName == expectation.caseName)
}

@Test func theLoggedCaseNameNeverIncludesTheAuthorizationFailureReason() {
    let failure = GoogleCalendarFailure.authorizationFailed(reason: "a reason that must not be logged")

    #expect(!failure.caseName.contains("reason"))
    #expect(failure.caseName == "authorizationFailed")
}

@Test func onlyAnAuthorizationFailureHasAReasonToLog() {
    #expect(GoogleCalendarFailure.authorizationFailed(reason: "the browser could not be opened").logReason == "the browser could not be opened")
    #expect(GoogleCalendarFailure.notAuthorized.logReason == nil)
    #expect(GoogleCalendarFailure.authorizationExpired.logReason == nil)
    #expect(GoogleCalendarFailure.unreachable.logReason == nil)
    #expect(GoogleCalendarFailure.rateLimited.logReason == nil)
    #expect(GoogleCalendarFailure.malformedResponse.logReason == nil)
}

@Test func failuresWithDifferentReasonsAreNotEqual() {
    #expect(GoogleCalendarFailure.authorizationFailed(reason: "a") != GoogleCalendarFailure.authorizationFailed(reason: "b"))
    #expect(GoogleCalendarFailure.authorizationFailed(reason: "a") == GoogleCalendarFailure.authorizationFailed(reason: "a"))
}
