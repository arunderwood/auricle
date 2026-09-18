import Foundation
@testable import Summarize
import Testing

private func date(_ iso: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: iso))
}

@Test func titleIsLocalTimeWithTheZoneAbbreviationInDaylightTime() throws {
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))

    let title = try UnenrichedMeetingTitle.title(captureStartedAt: date("2026-04-28T17:30:00Z"), in: zone)

    #expect(title == "Meeting at 2026-04-28T10:30 PDT")
}

@Test func titleUsesTheStandardTimeAbbreviationInWinter() throws {
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))

    let title = try UnenrichedMeetingTitle.title(captureStartedAt: date("2026-01-15T18:30:00Z"), in: zone)

    #expect(title == "Meeting at 2026-01-15T10:30 PST")
}

@Test func titleDateFollowsTheZoneAcrossMidnight() throws {
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))

    let title = try UnenrichedMeetingTitle.title(captureStartedAt: date("2026-04-29T03:05:00Z"), in: zone)

    #expect(title == "Meeting at 2026-04-28T20:05 PDT")
}
