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

@Test func enDashBetweenWordsKeepsThemSeparated() {
    let meeting = makeMeeting(calendarEventTitle: "Q3\u{2013}Q4 Planning")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-q3-q4-planning.md")
}

/// U+2010–U+2015 are dash punctuation; U+2212 is a math minus that titles use as a dash.
@Test(arguments: [
    "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}",
    "\u{FE58}", "\u{FF0D}",
])
func everyDashLikeCharacterSeparatesTheWordsAroundIt(dash: String) {
    let meeting = makeMeeting(calendarEventTitle: "Alpha\(dash)Beta")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-alpha-beta.md")
}

/// No-break space, en space, ideographic space, line separator, paragraph separator.
@Test(arguments: ["\u{00A0}", "\u{2002}", "\u{3000}", "\u{2028}", "\u{2029}"])
func everySpaceSeparatorSeparatesTheWordsAroundIt(space: String) {
    let meeting = makeMeeting(calendarEventTitle: "a\(space)b")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-a-b.md")
}

@Test func dashesAndSpacesAroundAWordCollapseIntoOneHyphenAndTrim() {
    let meeting = makeMeeting(calendarEventTitle: "\u{2014} Kick\u{00A0}\u{2013}\u{00A0}off \u{2014}")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-kick-off.md")
}

@Test func eszettTransliteratesToSS() {
    let meeting = makeMeeting(calendarEventTitle: "Große Runde")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-grosse-runde.md")
}

@Test func ligaturesTransliterateToTheirLetterPairs() {
    let meeting = makeMeeting(calendarEventTitle: "Æther Œuvre")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-aether-oeuvre.md")
}

@Test(arguments: [
    ("ß", "ss"), ("æ", "ae"), ("Æ", "ae"), ("œ", "oe"), ("Œ", "oe"),
    ("ø", "o"), ("Ø", "o"), ("đ", "d"), ("Đ", "d"), ("ð", "d"), ("Ð", "d"),
    ("þ", "th"), ("Þ", "th"), ("ł", "l"), ("Ł", "l"), ("ı", "i"),
])
func everyTransliterationTableEntryMapsToItsASCIIForm(letter: String, expected: String) {
    let meeting = makeMeeting(calendarEventTitle: "x\(letter)y")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-x\(expected)y.md")
}

@Test func transliterationDoesNotDisturbTextNFKDAlreadyHandles() {
    let meeting = makeMeeting(calendarEventTitle: "Café résumé Ærø")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-cafe-resume-aero.md")
}

@Test func aTitleOfOnlyDashesAndSpacesFallsThroughToTimeOfDay() {
    let meeting = makeMeeting(captureTime24h: "0815", calendarEventTitle: "\u{2013} \u{00A0} \u{2014}")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-0815.md")
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

@Test func aliasedAttendeeUsesTheAliasNotTheTarget() {
    let meeting = makeMeeting(attendees: ["[[People/Ben Smith|Ben]]"], selfWikilink: nil)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben.md")
}

@Test func attendeeWithAPathAndNoAliasUsesTheLastPathComponent() {
    let meeting = makeMeeting(attendees: ["[[People/Ben Smith]]"], selfWikilink: nil)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben-smith.md")
}

@Test func headingAndBlockSuffixesAreDroppedFromTheTarget() {
    let heading = makeMeeting(attendees: ["[[Ben#Notes]]"], selfWikilink: nil)
    let block = makeMeeting(attendees: ["[[Ben#^abc123]]"], selfWikilink: nil)
    let bareBlock = makeMeeting(attendees: ["[[Ben^abc123]]"], selfWikilink: nil)
    let nested = makeMeeting(attendees: ["[[People/Ben Smith#Notes|Ben]]"], selfWikilink: nil)
    #expect(FilenameResolver.resolve(meeting: heading) == "2026-04-28-with-ben.md")
    #expect(FilenameResolver.resolve(meeting: block) == "2026-04-28-with-ben.md")
    #expect(FilenameResolver.resolve(meeting: bareBlock) == "2026-04-28-with-ben.md")
    #expect(FilenameResolver.resolve(meeting: nested) == "2026-04-28-with-ben.md")
}

@Test func anEmptyAliasFallsBackToTheTargetsLastPathComponent() {
    let meeting = makeMeeting(attendees: ["[[People/Ben Smith|]]"], selfWikilink: nil)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben-smith.md")
}

@Test func anAttendeeWithoutBracketsIsReadAsATarget() {
    let meeting = makeMeeting(attendees: ["Ben"], selfWikilink: nil)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben.md")
}

@Test func aDuplicateAttendeeYieldsOneName() {
    let meeting = makeMeeting(attendees: ["[[Ben]]", "[[Ben]]"], selfWikilink: nil)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben.md")
}

@Test func duplicatesDoNotCountTowardTheTwoNameLimit() {
    let meeting = makeMeeting(attendees: ["[[Ben]]", "[[Ben]]", "[[Chris]]"], selfWikilink: nil)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben-and-chris.md")
}

@Test func attendeesWithDifferentCaseOrAliasShareAnIdentityAndKeepTheFirstOccurrence() {
    let meeting = makeMeeting(
        attendees: ["[[Ben|Benny]]", "[[Chris]]", "[[ben]]", "[[People/BEN|B]]"],
        selfWikilink: nil,
    )
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-benny-and-chris.md")
}

@Test func selfIsMatchedCaseInsensitively() {
    let meeting = makeMeeting(attendees: ["[[jordan]]", "[[Ben]]"], selfWikilink: "[[Jordan]]")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben.md")
}

@Test func selfIsMatchedThroughAliasPathAndHeadingVariants() {
    let meeting = makeMeeting(
        attendees: ["[[People/Jordan|JW]]", "[[Jordan#Notes]]", "[[Ben]]"],
        selfWikilink: "[[Jordan|Me]]",
    )
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-ben.md")
}

@Test func selfOnlyInVariantFormsStillFallsThroughToTimeOfDay() {
    let meeting = makeMeeting(
        captureTime24h: "1000",
        attendees: ["[[jordan]]", "[[People/Jordan|JW]]"],
        selfWikilink: "[[Jordan]]",
    )
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-1000.md")
}

@Test func attendeeNamesAreTransliteratedAndDashSeparated() {
    let meeting = makeMeeting(attendees: ["[[Jörg Groß\u{2013}Müller]]"], selfWikilink: nil)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-with-jorg-gross-muller.md")
}

// MARK: - Slug source 3: time of day

@Test func noCalendarTitleAndNoNamedAttributionUsesTimeOfDay() {
    let meeting = makeMeeting(captureTime24h: "1423", calendarEventTitle: nil, attendees: [])
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-1423.md")
}

@Test func aCaptureTimeWithPathCharactersCannotInjectThemIntoTheFilename() {
    let meeting = makeMeeting(captureTime24h: "10:30/../x")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at-10-30-x.md")
}

@Test func anEmptyCaptureTimeStillProducesANonEmptySlug() {
    let meeting = makeMeeting(captureTime24h: "")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at.md")
}

@Test func aCaptureTimeOfOnlySeparatorsStillProducesANonEmptySlug() {
    let meeting = makeMeeting(captureTime24h: "../\u{2013}/..")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-meeting-at.md")
}

@Test func anOverlongCaptureTimeIsCappedLikeAnyOtherSlug() {
    let meeting = makeMeeting(captureTime24h: String(repeating: "9", count: 100))
    let resolved = FilenameResolver.resolve(meeting: meeting)
    #expect(resolved == "2026-04-28-meeting-at.md")
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

@Test func aHyphenRightAfterTheCapKeepsTheWholeLastWord() {
    let firstWord = String(repeating: "a", count: 30)
    let secondWord = String(repeating: "b", count: 29)
    let meeting = makeMeeting(calendarEventTitle: "\(firstWord) \(secondWord) cccc")
    #expect("\(firstWord)-\(secondWord)".count == 60)
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-\(firstWord)-\(secondWord).md")
}

@Test func aWordStraddlingTheCapStillCutsAtTheLastEarlierHyphen() {
    let firstWord = String(repeating: "a", count: 30)
    let secondWord = String(repeating: "b", count: 40)
    let meeting = makeMeeting(calendarEventTitle: "\(firstWord) \(secondWord)")
    #expect(FilenameResolver.resolve(meeting: meeting) == "2026-04-28-\(firstWord).md")
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
