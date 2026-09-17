import Core
@testable import Persist
import Testing

private let meetingID = MeetingID(ulid: "01HJK3PQXY7N8M3FT4QHNWVZRP")!

/// Builds a fixture with sensible defaults; each test overrides only the
/// fields its scenario calls out, per the spec's I/O matrix.
private func makeMeeting(
    captureDate: String = "2026-04-28",
    captureTime24h: String = "1000",
    calendarEventTitle: String? = nil,
    attendees: [String] = [],
    selfWikilink: String? = nil,
) -> MeetingForFilename {
    MeetingForFilename(
        meetingID: meetingID,
        captureDate: captureDate,
        captureTime24h: captureTime24h,
        calendarEventTitle: calendarEventTitle,
        attendees: attendees,
        selfWikilink: selfWikilink,
    )
}

// MARK: - Slug source 1: calendar title

@Test func plainASCIICalendarTitleBecomesTheSlug() {
    let meeting = makeMeeting(calendarEventTitle: "Tuesday Sync")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-tuesday-sync.md")
}

@Test func accentedCalendarTitleDecomposesViaNFKD() {
    let meeting = makeMeeting(calendarEventTitle: "Café résumé")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-cafe-resume.md")
}

@Test func cjkCalendarTitleNormalizesToEmptyAndFallsThroughToTimeOfDay() {
    let meeting = makeMeeting(captureTime24h: "1423", calendarEventTitle: "北京会议", attendees: [])
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-1423.md")
}

@Test func allEmojiCalendarTitleNormalizesToEmptyAndFallsThroughToTimeOfDay() {
    let meeting = makeMeeting(captureTime24h: "0930", calendarEventTitle: "🎉🎉🎉", attendees: [])
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-0930.md")
}

@Test func mixedEmojiAndASCIICalendarTitleKeepsTheASCIIPortion() {
    let meeting = makeMeeting(calendarEventTitle: "🎉 Launch!")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-launch.md")
}

// MARK: - Slug source 2: named attendees

@Test func oneOnOneWithANamedAttendeeOmitsSelf() {
    let meeting = makeMeeting(attendees: ["[[Ben]]", "[[Jordan]]"], selfWikilink: "[[Jordan]]")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben.md")
}

@Test func selfPlusTwoNamedOthersJoinsBothWithAnd() {
    let meeting = makeMeeting(
        attendees: ["[[Jordan]]", "[[Ben]]", "[[Jordan Whitfield]]"],
        selfWikilink: "[[Jordan]]",
    )
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben-and-jordan-whitfield.md")
}

@Test func selfPlusThreeNamedOthersExceedsTheCapAndFallsThroughToTimeOfDay() {
    let meeting = makeMeeting(
        captureTime24h: "1000",
        attendees: ["[[Jordan]]", "[[Ben]]", "[[Chris]]", "[[Dana]]"],
        selfWikilink: "[[Jordan]]",
    )
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-1000.md")
}

@Test func threeAttendeesWithSelfNotIdentifiedNeverJoinsAllThree() {
    let meeting = makeMeeting(
        captureTime24h: "1000",
        attendees: ["[[Ben]]", "[[Chris]]", "[[Dana]]"],
        selfWikilink: nil,
    )
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-1000.md")
}

@Test func selfOnlyMeetingFallsThroughToTimeOfDay() {
    let meeting = makeMeeting(
        captureTime24h: "1000",
        attendees: ["[[Jordan]]"],
        selfWikilink: "[[Jordan]]",
    )
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-1000.md")
}

@Test func attendeesThatAllNormalizeToEmptyNeverProduceAGlueWordOnlySlug() {
    let meeting = makeMeeting(
        captureTime24h: "1000",
        attendees: ["[[北京]]", "[[东京]]"],
        selfWikilink: nil,
    )
    let resolved = FilenameResolver.resolve(meeting: meeting)
    #expect(resolved == "2026-04-28-meeting-at-1000.md")
    #expect(!resolved.contains("with-and"))
}

// MARK: - Slug source 3: time of day

@Test func noCalendarTitleAndNoNamedAttributionUsesTimeOfDay() {
    let meeting = makeMeeting(captureTime24h: "1423", calendarEventTitle: nil, attendees: [])
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-1423.md")
}

// MARK: - Source-1 length cap

@Test func extremelyLongCalendarTitleTruncatesAtTheLastHyphenAtOrBefore60Characters() {
    let meeting = makeMeeting(
        calendarEventTitle: "This is an extremely long meeting title that exceeds the slug length cap",
    )
    #expect(
        FilenameResolver.resolve(meeting: meeting)
            == "2026-04-28-this-is-an-extremely-long-meeting-title-that-exceeds-the.md",
    )
}

@Test func calendarTitleNormalizingToExactly60CharactersPassesThroughUnmodified() {
    let sixty = String(repeating: "a", count: 60)
    let meeting = makeMeeting(calendarEventTitle: sixty)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-\(sixty).md")
}

@Test func calendarTitleNormalizingToOneLongHyphenFreeRunHardCutsAt60Characters() {
    let meeting = makeMeeting(calendarEventTitle: String(repeating: "a", count: 70))
    let expectedSlug = String(repeating: "a", count: 60)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-\(expectedSlug).md")
}

// MARK: - Explicit empty string vs. nil

@Test func explicitEmptyStringCalendarTitleFallsThroughJustLikeNil() {
    let meeting = makeMeeting(
        captureTime24h: "1000",
        calendarEventTitle: "",
        attendees: ["[[Ben]]"],
    )
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben.md")
}

// MARK: - Source-2 per-name 25-character cap

@Test func twoLongAttendeeNamesAreEachCappedAt25CharactersBeforeJoining() {
    let meeting = makeMeeting(
        attendees: ["[[" + String(repeating: "a", count: 30) + "]]", "[[" + String(repeating: "b", count: 30) + "]]"],
        selfWikilink: nil,
    )
    let expectedSlug = "with-\(String(repeating: "a", count: 25))-and-\(String(repeating: "b", count: 25))"
    #expect(expectedSlug.count == 60)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-\(expectedSlug).md")
}

@Test func aSingleHyphenFreeAttendeeNameLongerThan25CharactersHardCutsRatherThanCollapsingToWith() {
    let meeting = makeMeeting(
        attendees: ["[[Jordan]]", "[[" + String(repeating: "x", count: 40) + "]]"],
        selfWikilink: "[[Jordan]]",
    )
    let expectedSlug = "with-\(String(repeating: "x", count: 25))"
    let resolved = FilenameResolver.resolve(meeting: meeting)
    #expect(resolved == "2026-04-28-\(expectedSlug).md")
    #expect(resolved != "2026-04-28-with.md")
}

@Test func exactlyOneOfTwoCandidateAttendeeNamesNormalizingToEmptyDiscardsOnlyThatOne() {
    let meeting = makeMeeting(attendees: ["[[Ben]]", "[[北京]]"], selfWikilink: nil)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben.md")
}

// MARK: - Ordinal suffix

@Test func noOrdinalOrOrdinalOneProducesNoSuffix() {
    let meeting = makeMeeting(calendarEventTitle: "Tuesday Sync")
    #expect(FilenameResolver.resolve(meeting: meeting, ordinal: nil) == "2026-04-28-tuesday-sync.md")
    #expect(FilenameResolver.resolve(meeting: meeting, ordinal: 1) == "2026-04-28-tuesday-sync.md")
}

@Test func ordinalTwoOrGreaterInsertsTheCounterBeforeTheExtension() {
    let meeting = makeMeeting(calendarEventTitle: "Tuesday Sync")
    #expect(FilenameResolver.resolve(meeting: meeting, ordinal: 2) == "2026-04-28-tuesday-sync-2.md")
}
