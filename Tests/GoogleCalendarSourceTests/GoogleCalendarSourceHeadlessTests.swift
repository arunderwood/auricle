import CalendarInterface
import Core
import Foundation
@testable import GoogleCalendarSource
import Testing

@Test func headlessSourceIsNilWithoutAClientID() {
    #expect(GoogleCalendarSource.headless(Config.GoogleCalendar()) == nil)
    #expect(GoogleCalendarSource.headless(Config.GoogleCalendar(clientSecret: "only-a-secret")) == nil)
}

@Test func headlessSourceExistsWhenAClientIDIsConfigured() {
    #expect(GoogleCalendarSource.headless(Config.GoogleCalendar(clientID: "client.apps.googleusercontent.com")) != nil)
    #expect(GoogleCalendarSource.headless(Config.GoogleCalendar(clientID: "client", clientSecret: "secret")) != nil)
}

@Test func theHeadlessBrowserOpenerThrowsRatherThanOpeningAnything() async throws {
    await #expect(throws: HeadlessAuthorizationUnavailable.self) {
        try await GoogleCalendarSource.headlessBrowserOpener(#require(URL(string: "https://accounts.example.invalid/authorize")))
    }
}

@Test(.timeLimit(.minutes(1)))
func authorizingAHeadlessSourceFailsAtOnceAndStoresNothing() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        redirectTimeout: .seconds(3600),
        openBrowser: GoogleCalendarSource.headlessBrowserOpener,
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }

    #expect(harness.storedRefreshToken == nil)
    #expect(harness.stub.tokenRequests.isEmpty)
}
