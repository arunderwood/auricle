import Core
@testable import Persist
import Testing

/// Renders `meeting` (the standard-variant fixture from
/// `FrontmatterRendererTests.swift` by default) and replaces one exact
/// substring in the output -- corrupting a single scalar's shape without
/// hand-building a whole second fixture that could drift from
/// `FrontmatterRenderer`'s real output.
private func corrupting(
    _ target: String,
    in meeting: MeetingForFrontmatter = makeMeeting(),
    with replacement: String,
) -> String {
    FrontmatterRenderer.render(meeting: meeting).replacingOccurrences(of: target, with: replacement)
}

private func expectMalformedFrontmatter(reading noteContents: String, reasonContaining expectedReason: String? = nil) {
    do {
        _ = try FrontmatterReader.read(noteContents: noteContents)
        Issue.record("Expected FrontmatterReader.ReadError.malformedFrontmatter, got no error")
    } catch let FrontmatterReader.ReadError.malformedFrontmatter(reason) {
        if let expectedReason {
            #expect(reason.contains(expectedReason))
        }
    } catch {
        Issue.record("Expected FrontmatterReader.ReadError.malformedFrontmatter, got \(error)")
    }
}

private func expectNotAnAuricleNote(reading noteContents: String) {
    do {
        _ = try FrontmatterReader.read(noteContents: noteContents)
        Issue.record("Expected FrontmatterReader.ReadError.notAnAuricleNote, got no error")
    } catch FrontmatterReader.ReadError.notAnAuricleNote {
        // expected
    } catch {
        Issue.record("Expected FrontmatterReader.ReadError.notAnAuricleNote, got \(error)")
    }
}

@Test func validV1FixtureReadsBackMeetingIDAttendeesAndSupersedes() throws {
    let meeting = makeMeeting()
    let result = try FrontmatterReader.read(noteContents: FrontmatterRenderer.render(meeting: meeting))

    #expect(result == FrontmatterReader.FrontmatterV1(
        meetingID: meeting.meetingID,
        schemaVersion: 1,
        attendees: ["[[Ben]]"],
        supersedes: nil,
    ))
}

@Test func unknownFieldUnderAuricleIsIgnoredAndSchemaVersionStaysOne() throws {
    let meeting = makeMeeting()
    let rendered = corrupting(
        "  schema_version: 1\n",
        in: meeting,
        with: "  schema_version: 1\n  future_field: \"x\"\n",
    )
    let result = try FrontmatterReader.read(noteContents: rendered)

    #expect(result == FrontmatterReader.FrontmatterV1(
        meetingID: meeting.meetingID,
        schemaVersion: 1,
        attendees: ["[[Ben]]"],
        supersedes: nil,
    ))
}

@Test func supersedesRoundTripsWhenPresent() throws {
    let meeting = makeMeeting(supersedes: "2026-04-28-tuesday-sync-with-ben.md")
    let result = try FrontmatterReader.read(noteContents: FrontmatterRenderer.render(meeting: meeting))

    #expect(result.supersedes == "2026-04-28-tuesday-sync-with-ben.md")
}

@Test func emptyAttendeesRoundTripsToAnEmptyArray() throws {
    let meeting = makeMeeting(attendees: [], needsCalendarEnrichment: true)
    let result = try FrontmatterReader.read(noteContents: FrontmatterRenderer.render(meeting: meeting))

    #expect(result.attendees == [])
}

@Test func schemaVersionZeroThrowsTooOld() {
    let rendered = corrupting("  schema_version: 1\n", with: "  schema_version: 0\n")

    do {
        _ = try FrontmatterReader.read(noteContents: rendered)
        Issue.record("Expected FrontmatterReader.ReadError.schemaVersionTooOld, got no error")
    } catch let FrontmatterReader.ReadError.schemaVersionTooOld(found, oldestSupported) {
        #expect(found == 0)
        #expect(oldestSupported == 1)
    } catch {
        Issue.record("Expected FrontmatterReader.ReadError.schemaVersionTooOld, got \(error)")
    }
}

@Test func schemaVersionNineNinetyNineThrowsTooNew() {
    let rendered = corrupting("  schema_version: 1\n", with: "  schema_version: 999\n")

    do {
        _ = try FrontmatterReader.read(noteContents: rendered)
        Issue.record("Expected FrontmatterReader.ReadError.schemaVersionTooNew, got no error")
    } catch let FrontmatterReader.ReadError.schemaVersionTooNew(found, newestSupported) {
        #expect(found == 999)
        #expect(newestSupported == 1)
    } catch {
        Issue.record("Expected FrontmatterReader.ReadError.schemaVersionTooNew, got \(error)")
    }
}

@Test func malformedAttendeesShapeThrowsMalformedFrontmatter() {
    let rendered = corrupting(
        "attendees:\n  - \"[[Ben]]\"\n",
        with: "attendees: \"not-a-list\"\n",
    )
    expectMalformedFrontmatter(reading: rendered)
}

@Test func malformedSupersedesShapeThrowsMalformedFrontmatter() {
    let meeting = makeMeeting(supersedes: "2026-04-28-tuesday-sync-with-ben.md")
    let rendered = corrupting(
        "  supersedes: \"2026-04-28-tuesday-sync-with-ben.md\"\n",
        in: meeting,
        with: "  supersedes:\n    nested: true\n",
    )
    expectMalformedFrontmatter(reading: rendered)
}

@Test func invalidMeetingIDShapeThrowsMalformedFrontmatter() {
    let rendered = corrupting(
        "  meeting_id: \"01HJK3PQXY7N8M3FT4QHNWVZRP\"\n",
        with: "  meeting_id: \"not-a-valid-ulid\"\n",
    )
    expectMalformedFrontmatter(reading: rendered)
}

@Test func missingClosingFenceThrowsMalformedFrontmatter() {
    let rendered = corrupting("\n---\n\n", with: "\n\n")
    expectMalformedFrontmatter(reading: rendered)
}

@Test func frontmatterWithNoAuricleBlockThrowsNotAnAuricleNote() {
    let noteWithoutAuricleBlock = """
    ---
    title: "Some Note"
    date: 2026-04-28
    tags:
      - personal
    ---

    Just a random Obsidian note, not one of ours.

    """

    expectNotAnAuricleNote(reading: noteWithoutAuricleBlock)
}

@Test func aCRLFNoteReadsTheSameAsItsLFVersion() throws {
    let meeting = makeMeeting(supersedes: "2026-04-28-tuesday-sync-with-ben.md")
    let lfNote = FrontmatterRenderer.render(meeting: meeting)
    let crlfNote = lfNote.replacingOccurrences(of: "\n", with: "\r\n")

    #expect(crlfNote.unicodeScalars.contains("\r"))
    #expect(try FrontmatterReader.read(noteContents: crlfNote) == FrontmatterReader.read(noteContents: lfNote))
}

@Test func anUnquotedWikilinkAttendeeParsesAsANestedSequenceAndThrowsMalformedFrontmatter() {
    let rendered = corrupting(
        "attendees:\n  - \"[[Ben]]\"\n",
        with: "attendees:\n  - [[Ben]]\n",
    )
    expectMalformedFrontmatter(reading: rendered, reasonContaining: "non-string element")
}

@Test func anEmptyFrontmatterBlockThrowsNotAnAuricleNote() {
    expectNotAnAuricleNote(reading: "---\n---\n")
}

// MARK: - Editor-produced input

@Test func aLeadingByteOrderMarkIsIgnored() throws {
    let lfNote = FrontmatterRenderer.render(meeting: makeMeeting(supersedes: "2026-04-28-tuesday-sync-with-ben.md"))
    let bomNote = "\u{FEFF}" + lfNote

    #expect(bomNote.unicodeScalars.first == "\u{FEFF}")
    #expect(try FrontmatterReader.read(noteContents: bomNote) == FrontmatterReader.read(noteContents: lfNote))
}

@Test func aByteOrderMarkOnACRLFNoteIsIgnored() throws {
    let lfNote = FrontmatterRenderer.render(meeting: makeMeeting())
    let bomCRLFNote = "\u{FEFF}" + lfNote.replacingOccurrences(of: "\n", with: "\r\n")

    #expect(try FrontmatterReader.read(noteContents: bomCRLFNote) == FrontmatterReader.read(noteContents: lfNote))
}

@Test(arguments: [" ", "\t", "  \t "])
func trailingWhitespaceOnTheOpeningFenceIsAccepted(trailing: String) throws {
    let lfNote = FrontmatterRenderer.render(meeting: makeMeeting())
    let padded = "---" + trailing + "\n" + lfNote.dropFirst("---\n".count)

    #expect(try FrontmatterReader.read(noteContents: padded) == FrontmatterReader.read(noteContents: lfNote))
}

@Test(arguments: [" ", "\t", "  \t "])
func trailingWhitespaceOnTheClosingFenceIsAccepted(trailing: String) throws {
    let lfNote = FrontmatterRenderer.render(meeting: makeMeeting())
    let padded = corrupting("\n---\n\n", with: "\n---" + trailing + "\n\n")

    #expect(padded != lfNote)
    #expect(try FrontmatterReader.read(noteContents: padded) == FrontmatterReader.read(noteContents: lfNote))
}

@Test func aLineThatOnlyStartsWithThreeDashesIsNotAClosingFence() {
    expectMalformedFrontmatter(
        reading: corrupting("\n---\n\n", with: "\n----\n\n"),
        reasonContaining: "closing fence",
    )
}

@Test(arguments: ["", "\n", "Just a plain note, no frontmatter.\n", "\n---\ntitle: x\n---\n", "# Heading\n\n---\n\nbody\n"])
func aNoteWhoseFirstLineIsNotAFenceThrowsNotAnAuricleNote(noteContents: String) {
    expectNotAnAuricleNote(reading: noteContents)
}

@Test func aFrontmatterBlockThatNeverClosesStaysMalformed() {
    expectMalformedFrontmatter(reading: "---\ntitle: x\n", reasonContaining: "closing fence")
}

@Test func anAbsentSchemaVersionThrowsNotAnAuricleNote() {
    expectNotAnAuricleNote(reading: corrupting("  schema_version: 1\n", with: ""))
}

@Test(arguments: [
    "  schema_version: \"v2\"\n",
    "  schema_version: v2\n",
    "  schema_version: 2.0\n",
    "  schema_version:\n",
    "  schema_version: null\n",
    "  schema_version: ~\n",
    "  schema_version: true\n",
])
func aNonIntegerSchemaVersionThrowsMalformedFrontmatter(line: String) {
    expectMalformedFrontmatter(
        reading: corrupting("  schema_version: 1\n", with: line),
        reasonContaining: "schema_version",
    )
}

@Test(arguments: ["attendees:\n", "attendees: null\n", "attendees: ~\n", "attendees: Null\n"])
func aNullAttendeesValueDecodesToAnEmptyArray(line: String) throws {
    let rendered = corrupting("attendees:\n  - \"[[Ben]]\"\n", with: line)
    let result = try FrontmatterReader.read(noteContents: rendered)

    #expect(result.attendees == [])
}

@Test func aQuotedNullAttendeesValueIsAStringNotANull() {
    let rendered = corrupting("attendees:\n  - \"[[Ben]]\"\n", with: "attendees: \"null\"\n")
    expectMalformedFrontmatter(reading: rendered, reasonContaining: "not a sequence")
}

@Test(arguments: ["  supersedes:\n", "  supersedes: null\n", "  supersedes: ~\n", "  supersedes: NULL\n"])
func aNullSupersedesValueDecodesToNil(line: String) throws {
    let meeting = makeMeeting(supersedes: "2026-04-28-tuesday-sync-with-ben.md")
    let rendered = corrupting(
        "  supersedes: \"2026-04-28-tuesday-sync-with-ben.md\"\n",
        in: meeting,
        with: line,
    )
    let result = try FrontmatterReader.read(noteContents: rendered)

    #expect(result.supersedes == nil)
    #expect(result.meetingID == meeting.meetingID)
}

@Test func aQuotedNullSupersedesValueStaysTheStringNull() throws {
    let meeting = makeMeeting(supersedes: "2026-04-28-tuesday-sync-with-ben.md")
    let rendered = corrupting(
        "  supersedes: \"2026-04-28-tuesday-sync-with-ben.md\"\n",
        in: meeting,
        with: "  supersedes: \"null\"\n",
    )
    let result = try FrontmatterReader.read(noteContents: rendered)

    #expect(result.supersedes == "null")
}
