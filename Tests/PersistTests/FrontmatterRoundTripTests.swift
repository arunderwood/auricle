import Core
@testable import Persist
import Testing
import Yams

/// The frontmatter block of a rendered note as a composed `Node`: the reader
/// deliberately drops `title`, so a test that needs the title back goes
/// through the YAML parser directly.
private func composedFrontmatter(of note: String) throws -> Node {
    let lines = note.split(separator: "\n", omittingEmptySubsequences: false)
    let closingFenceIndex = try #require(lines.dropFirst().firstIndex(of: "---"))
    let yaml = lines[1 ..< closingFenceIndex].joined(separator: "\n")
    return try #require(try Yams.compose(yaml: yaml))
}

@Test func hostileCharactersInTitleAttendeesAndSupersedesRoundTrip() throws {
    let title = #"Review "Project X": a\b # c"#
    let attendees = [#"[[Sean "Mac" O'Neil]]"#, "[[Ben]]"]
    let supersedes = #"x"y.md"#
    let meeting = makeMeeting(title: title, attendees: attendees, supersedes: supersedes)

    let rendered = FrontmatterRenderer.render(meeting: meeting)
    let result = try FrontmatterReader.read(noteContents: rendered)

    #expect(result.attendees == attendees)
    #expect(result.supersedes == supersedes)
    #expect(result.meetingID == meeting.meetingID)
    #expect(result.schemaVersion == 1)
    #expect(try composedFrontmatter(of: rendered)["title"]?.string == title)

    let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.first == "---")
    #expect(lines.filter { $0 == "---" }.count == 2)
    let closingFenceIndex = try #require(lines.dropFirst().firstIndex(of: "---"))
    #expect(lines[closingFenceIndex + 1].isEmpty)
    #expect(lines[closingFenceIndex + 2] == meeting.summary)
}

@Test func aNoteRenderedAtTheCurrentSchemaVersionReadsBackAtTheCurrentSchemaVersion() throws {
    let base = makeMeeting()
    let meeting = MeetingForFrontmatter(
        meetingID: base.meetingID,
        title: base.title,
        date: base.date,
        attendees: base.attendees,
        schemaVersion: FrontmatterSchema.current,
        supersedes: base.supersedes,
        needsAttribution: base.needsAttribution,
        needsCalendarEnrichment: base.needsCalendarEnrichment,
        summary: base.summary,
        actionItems: base.actionItems,
        decisions: base.decisions,
        transcriptSegments: base.transcriptSegments,
    )

    let result = try FrontmatterReader.read(noteContents: FrontmatterRenderer.render(meeting: meeting))

    #expect(result.schemaVersion == FrontmatterSchema.current)
    #expect(result.meetingID == meeting.meetingID)
}

@Test func aNewlineFollowedByASequenceMarkerNeverCorruptsAScalar() throws {
    let title = "Weekly\n- d"
    let attendee = "[[Ben\n- e]]"
    let meeting = makeMeeting(title: title, attendees: [attendee, "[[Ann]]"])

    let rendered = FrontmatterRenderer.render(meeting: meeting)
    let result = try FrontmatterReader.read(noteContents: rendered)

    #expect(result.attendees == [attendee, "[[Ann]]"])
    #expect(try composedFrontmatter(of: rendered)["title"]?.string == title)
}

@Test func aTitleWithCodePointsAboveTheBasicMultilingualPlaneRoundTripsAsAYAMLValue() throws {
    // libyaml cannot emit code points above U+FFFF as literal text, so it
    // writes the emoji as a `\U0001F389` escape and passes the rest through.
    // The raw file therefore differs from the input, but every YAML reader
    // decodes the escape, so the value itself round-trips.
    let title = "🎉 Launch é 北京"
    let meeting = makeMeeting(title: title)

    let rendered = FrontmatterRenderer.render(meeting: meeting)
    let result = try FrontmatterReader.read(noteContents: rendered)

    #expect(try composedFrontmatter(of: rendered)["title"]?.string == title)
    #expect(result.attendees == ["[[Ben]]"])
    #expect(result.meetingID == meeting.meetingID)
}
