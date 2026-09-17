import Core
@testable import Persist
import Testing
import TestSupport

private let meetingID = MeetingID(ulid: "01HJK3PQXY7N8M3FT4QHNWVZRP")!

/// Builds the standard-variant fixture by default; each test overrides only
/// the fields its scenario calls out, per the spec's I/O matrix.
private func makeMeeting(
    title: String = "Tuesday Sync with Ben",
    attendees: [String] = ["[[Ben]]"],
    supersedes: String? = nil,
    needsAttribution: Bool = false,
    needsCalendarEnrichment: Bool = false,
    summary: String = "Ben and the team reviewed the project timeline and agreed to move up the launch date.",
    actionItems: [QuotedItem] = [
        QuotedItem(
            text: "[[Ben]] will draft the project brief by end of week",
            quote: "I'll take a first pass at the brief by Friday",
        ),
    ],
    decisions: [QuotedItem] = [
        QuotedItem(
            text: "Move the launch date to May 15",
            quote: "Yeah let's push it to the 15th, that gives us another week",
        ),
    ],
    transcriptSegments: [TranscriptSegment] = [
        TranscriptSegment(speaker: "[[Ben]]", text: "I'll take a first pass at the brief by Friday."),
    ],
    audioPath: String? = nil,
    calendarEventID: String? = nil,
    retentionPolicy: String? = nil,
) -> MeetingForFrontmatter {
    MeetingForFrontmatter(
        meetingID: meetingID,
        title: title,
        date: "2026-04-28",
        attendees: attendees,
        schemaVersion: 1,
        supersedes: supersedes,
        needsAttribution: needsAttribution,
        needsCalendarEnrichment: needsCalendarEnrichment,
        summary: summary,
        actionItems: actionItems,
        decisions: decisions,
        transcriptSegments: transcriptSegments,
        audioPath: audioPath,
        calendarEventID: calendarEventID,
        retentionPolicy: retentionPolicy,
    )
}

@Test func standardVariantMatchesTheGoldenFixtureExactly() {
    let standardGolden = """
    ---
    title: "Tuesday Sync with Ben"
    date: 2026-04-28
    tags:
      - auricle/meeting
    attendees:
      - "[[Ben]]"
    auricle:
      meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"
      schema_version: 1
    ---

    Ben and the team reviewed the project timeline and agreed to move up the launch date.

    ## Action Items

    - [[Ben]] will draft the project brief by end of week
      > I'll take a first pass at the brief by Friday

    ## Decisions

    - Move the launch date to May 15
      > Yeah let's push it to the 15th, that gives us another week

    ## Transcript

    **[[Ben]]:** I'll take a first pass at the brief by Friday.

    """
    let rendered = FrontmatterRenderer.render(meeting: makeMeeting())
    #expect(rendered == standardGolden)
}

@Test func publishAnywayVariantAddsNeedsAttributionTagAndPlaceholderAttendees() {
    let meeting = makeMeeting(
        attendees: ["[[Speaker_1]]", "[[Speaker_2]]"],
        needsAttribution: true,
    )
    let expected = """
    ---
    title: "Tuesday Sync with Ben"
    date: 2026-04-28
    tags:
      - auricle/meeting
      - auricle/needs-attribution
    attendees:
      - "[[Speaker_1]]"
      - "[[Speaker_2]]"
    auricle:
      meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"
      schema_version: 1
    ---

    Ben and the team reviewed the project timeline and agreed to move up the launch date.

    ## Action Items

    - [[Ben]] will draft the project brief by end of week
      > I'll take a first pass at the brief by Friday

    ## Decisions

    - Move the launch date to May 15
      > Yeah let's push it to the 15th, that gives us another week

    ## Transcript

    **[[Ben]]:** I'll take a first pass at the brief by Friday.

    """
    #expect(FrontmatterRenderer.render(meeting: meeting) == expected)
}

@Test func calendarEnrichmentFailedVariantAddsTagGenericTitleAndEmptyAttendees() {
    let meeting = makeMeeting(
        title: "Meeting at 2026-04-28T10:30 PT",
        attendees: [],
        needsCalendarEnrichment: true,
    )
    let expected = """
    ---
    title: "Meeting at 2026-04-28T10:30 PT"
    date: 2026-04-28
    tags:
      - auricle/meeting
      - auricle/needs-calendar-enrichment
    attendees: []
    auricle:
      meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"
      schema_version: 1
    ---

    Ben and the team reviewed the project timeline and agreed to move up the launch date.

    ## Action Items

    - [[Ben]] will draft the project brief by end of week
      > I'll take a first pass at the brief by Friday

    ## Decisions

    - Move the launch date to May 15
      > Yeah let's push it to the 15th, that gives us another week

    ## Transcript

    **[[Ben]]:** I'll take a first pass at the brief by Friday.

    """
    #expect(FrontmatterRenderer.render(meeting: meeting) == expected)
}

@Test func republishedVariantAddsSupersedesAfterSchemaVersionWithNoExtraTag() {
    let meeting = makeMeeting(supersedes: "2026-04-28-tuesday-sync-with-ben.md")
    let expected = """
    ---
    title: "Tuesday Sync with Ben"
    date: 2026-04-28
    tags:
      - auricle/meeting
    attendees:
      - "[[Ben]]"
    auricle:
      meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"
      schema_version: 1
      supersedes: "2026-04-28-tuesday-sync-with-ben.md"
    ---

    Ben and the team reviewed the project timeline and agreed to move up the launch date.

    ## Action Items

    - [[Ben]] will draft the project brief by end of week
      > I'll take a first pass at the brief by Friday

    ## Decisions

    - Move the launch date to May 15
      > Yeah let's push it to the 15th, that gives us another week

    ## Transcript

    **[[Ben]]:** I'll take a first pass at the brief by Friday.

    """
    #expect(FrontmatterRenderer.render(meeting: meeting) == expected)
}

@Test func combinationOfPublishAnywayAndCalendarFailedAppliesBothTagsAndShapeChanges() {
    let meeting = makeMeeting(
        title: "Meeting at 2026-04-28T10:30 PT",
        attendees: [],
        needsAttribution: true,
        needsCalendarEnrichment: true,
    )
    let expected = """
    ---
    title: "Meeting at 2026-04-28T10:30 PT"
    date: 2026-04-28
    tags:
      - auricle/meeting
      - auricle/needs-attribution
      - auricle/needs-calendar-enrichment
    attendees: []
    auricle:
      meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"
      schema_version: 1
    ---

    Ben and the team reviewed the project timeline and agreed to move up the launch date.

    ## Action Items

    - [[Ben]] will draft the project brief by end of week
      > I'll take a first pass at the brief by Friday

    ## Decisions

    - Move the launch date to May 15
      > Yeah let's push it to the 15th, that gives us another week

    ## Transcript

    **[[Ben]]:** I'll take a first pass at the brief by Friday.

    """
    #expect(FrontmatterRenderer.render(meeting: meeting) == expected)
}

@Test func emptyActionItemsAndDecisionsStillRenderTheirHeadingsWithNoBullets() {
    let meeting = makeMeeting(actionItems: [], decisions: [])
    let expected = """
    ---
    title: "Tuesday Sync with Ben"
    date: 2026-04-28
    tags:
      - auricle/meeting
    attendees:
      - "[[Ben]]"
    auricle:
      meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"
      schema_version: 1
    ---

    Ben and the team reviewed the project timeline and agreed to move up the launch date.

    ## Action Items

    ## Decisions

    ## Transcript

    **[[Ben]]:** I'll take a first pass at the brief by Friday.

    """
    #expect(FrontmatterRenderer.render(meeting: meeting) == expected)
}

@Test func emptyTranscriptSegmentsStillRendersTheHeadingWithNoParagraphs() {
    let meeting = makeMeeting(transcriptSegments: [])
    let expected = """
    ---
    title: "Tuesday Sync with Ben"
    date: 2026-04-28
    tags:
      - auricle/meeting
    attendees:
      - "[[Ben]]"
    auricle:
      meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"
      schema_version: 1
    ---

    Ben and the team reviewed the project timeline and agreed to move up the launch date.

    ## Action Items

    - [[Ben]] will draft the project brief by end of week
      > I'll take a first pass at the brief by Friday

    ## Decisions

    - Move the launch date to May 15
      > Yeah let's push it to the 15th, that gives us another week

    ## Transcript

    """
    #expect(FrontmatterRenderer.render(meeting: meeting) == expected)
}

@Test func operationalFieldsNeverAppearInTheRenderedOutput() {
    let meeting = makeMeeting(
        audioPath: "/Users/someone/Library/Caches/com.auricle.app/01HJK3PQXY7N8M3FT4QHNWVZRP/audio.wav",
        calendarEventID: "google:abc123",
        retentionPolicy: "custom:30",
    )
    let rendered = FrontmatterRenderer.render(meeting: meeting)

    #expect(!rendered.contains("audio.wav"))
    #expect(!rendered.contains("google:abc123"))
    #expect(!rendered.contains("custom:30"))
    #expect(!rendered.contains("audioPath"))
    #expect(!rendered.contains("calendarEventID"))
    #expect(!rendered.contains("retentionPolicy"))
}

@Test func everyVariantAndTheCombinationPassMarkdownDiscipline() {
    let variants = [
        makeMeeting(),
        makeMeeting(attendees: ["[[Speaker_1]]", "[[Speaker_2]]"], needsAttribution: true),
        makeMeeting(title: "Meeting at 2026-04-28T10:30 PT", attendees: [], needsCalendarEnrichment: true),
        makeMeeting(supersedes: "2026-04-28-tuesday-sync-with-ben.md"),
        makeMeeting(
            title: "Meeting at 2026-04-28T10:30 PT",
            attendees: [],
            needsAttribution: true,
            needsCalendarEnrichment: true,
        ),
    ]

    for meeting in variants {
        let rendered = FrontmatterRenderer.render(meeting: meeting)
        #expect(MarkdownDisciplineChecker.check(rendered).isEmpty)
    }
}

@Test func nonASCIICharactersInTitleAndAttendeesRenderAsLiteralTextNotEscapeSequences() {
    let meeting = makeMeeting(
        title: "Café Sync with 王芳 — Q3 Planning",
        attendees: ["[[François]]"],
    )
    let rendered = FrontmatterRenderer.render(meeting: meeting)

    #expect(rendered.contains("Café Sync with 王芳 — Q3 Planning"))
    #expect(rendered.contains("[[François]]"))
    #expect(!rendered.contains("\\u"))
}

@Test func longTitleRendersOnASingleUnwrappedLine() {
    let longTitle = "Quarterly Business Review and Strategic Planning Session for the Whole Engineering Org"
    let meeting = makeMeeting(title: longTitle)
    let rendered = FrontmatterRenderer.render(meeting: meeting)
    let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    #expect(lines[1] == "title: \"\(longTitle)\"")
}

@Test func emptySummaryLeavesExactlyOneBlankLineAfterTheFrontmatterFence() {
    let meeting = makeMeeting(summary: "")
    let rendered = FrontmatterRenderer.render(meeting: meeting)
    let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let closingFenceIndex = lines.indices.filter { lines[$0] == "---" }[1]

    #expect(lines[closingFenceIndex + 1].isEmpty)
    #expect(lines[closingFenceIndex + 2] == "## Action Items")
}
