import CalendarInterface
import Testing

@Test func calendarErrorCasesAreEquatableAndDistinct() {
    #expect(CalendarError.unreachable == CalendarError.unreachable)
    #expect(CalendarError.authorizationExpired == CalendarError.authorizationExpired)
    #expect(CalendarError.unreachable != CalendarError.authorizationExpired)
}

@Test func calendarErrorCasesAreNamedByTheirCaseAlone() {
    #expect(String(describing: CalendarError.unreachable) == "unreachable")
    #expect(String(describing: CalendarError.authorizationExpired) == "authorizationExpired")
}
