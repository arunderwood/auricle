/// The `summary.json` cache-artifact contract (cache-artifact JSON dialect,
/// `Core/Codable+Dialects.swift`): `PersistStage`'s sole input for building
/// `MeetingForFrontmatter`/`MeetingForFilename`, produced upstream by the
/// summarize stage (or, in Epic 2's own validation scope, a fixture standing
/// in for it — see `epic-2-context.md`'s synthetic-input note).
///
/// `title` and `calendarEventTitle` are deliberately separate fields: `title`
/// is the frontmatter-display title, already carrying any "Meeting at
/// <HHMM>" fallback the upstream stage applied when calendar enrichment
/// failed (Decision 2.2's variant tagging); `calendarEventTitle` is `nil` in
/// that same failure case and feeds only `FilenameResolver`'s slug-source-1
/// (Decision 2.4) — a `title` fallback string must never leak into the
/// filename slug chain, which has its own independent fallbacks.
public struct SummaryArtifact: Codable, Equatable {
    public let title: String
    public let calendarEventTitle: String?
    /// Already wikilink-formatted (e.g. `"[[Ben]]"` or `"[[Speaker_1]]"`),
    /// per the upstream stage's attribution pass — `PersistStage` never
    /// wikilinks a name itself.
    public let attendees: [String]
    public let selfWikilink: String?
    public let needsAttribution: Bool
    public let needsCalendarEnrichment: Bool
    /// One paragraph, already wikilinked.
    public let summary: String
    public let actionItems: [QuotedItemArtifact]
    public let decisions: [QuotedItemArtifact]
    public let transcriptSegments: [TranscriptSegmentArtifact]

    enum CodingKeys: String, CodingKey {
        case title
        case calendarEventTitle = "calendar_event_title"
        case attendees
        case selfWikilink = "self_wikilink"
        case needsAttribution = "needs_attribution"
        case needsCalendarEnrichment = "needs_calendar_enrichment"
        case summary
        case actionItems = "action_items"
        case decisions
        case transcriptSegments = "transcript_segments"
    }

    public init(
        title: String,
        calendarEventTitle: String?,
        attendees: [String],
        selfWikilink: String?,
        needsAttribution: Bool,
        needsCalendarEnrichment: Bool,
        summary: String,
        actionItems: [QuotedItemArtifact],
        decisions: [QuotedItemArtifact],
        transcriptSegments: [TranscriptSegmentArtifact],
    ) {
        self.title = title
        self.calendarEventTitle = calendarEventTitle
        self.attendees = attendees
        self.selfWikilink = selfWikilink
        self.needsAttribution = needsAttribution
        self.needsCalendarEnrichment = needsCalendarEnrichment
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.transcriptSegments = transcriptSegments
    }
}

/// Maps onto `MeetingForFrontmatter`'s `QuotedItem`
/// (`Sources/Persist/MeetingForFrontmatter.swift:67-75`) — a separate type
/// because the cache-artifact dialect and the renderer's own input contract
/// are independent boundaries that happen to share a shape today.
public struct QuotedItemArtifact: Codable, Equatable {
    public let text: String
    public let quote: String

    public init(text: String, quote: String) {
        self.text = text
        self.quote = quote
    }
}

/// Maps onto `MeetingForFrontmatter`'s `TranscriptSegment`
/// (`Sources/Persist/MeetingForFrontmatter.swift:78-86`).
public struct TranscriptSegmentArtifact: Codable, Equatable {
    public let speaker: String
    public let text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}
