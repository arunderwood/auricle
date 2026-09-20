/// The `summary.json` cache-artifact contract (cache-artifact JSON dialect,
/// `Core/Codable+Dialects.swift`): written by `SummarizeStage` and read by
/// `PersistStage`, which builds `MeetingForFrontmatter`/`MeetingForFilename`
/// from it. It lives in `Core` because neither stage may import the other.
///
/// `title` and `calendarEventTitle` are deliberately separate fields: `title`
/// is the frontmatter-display title; when no calendar event enriched the
/// meeting it is the generic `Meeting at YYYY-MM-DDTHH:mm <zone abbreviation>`
/// (Decision 2.2's calendar-failed variant, e.g. `Meeting at 2026-04-28T10:30
/// PDT`), in the capture's local time. `calendarEventTitle` is `nil` in that
/// same case and feeds only `FilenameResolver`'s slug-source-1 (Decision 2.4)
/// — a `title` fallback string must never leak into the filename slug chain,
/// which has its own independent fallbacks.
public struct SummaryArtifact: Codable, Equatable, Sendable {
    public let title: String
    public let calendarEventTitle: String?
    /// Already wikilink-formatted (e.g. `"[[Ben]]"` or `"[[Speaker_1]]"`),
    /// per the upstream stage's attribution pass — `PersistStage` never
    /// wikilinks a name itself.
    public let attendees: [String]
    public let selfWikilink: String?
    public let needsAttribution: Bool
    public let needsCalendarEnrichment: Bool
    /// Set on the stub a failed summarize leaves for `--publish-anyway`: the
    /// note publishes without a summary, action items or decisions, and the
    /// meeting completes into `published_partial`.
    public let needsSummary: Bool
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
        case needsSummary = "needs_summary"
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
        needsSummary: Bool = false,
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
        self.needsSummary = needsSummary
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.transcriptSegments = transcriptSegments
    }

    /// An absent `needs_summary` key means a complete summary.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        calendarEventTitle = try container.decodeIfPresent(String.self, forKey: .calendarEventTitle)
        attendees = try container.decode([String].self, forKey: .attendees)
        selfWikilink = try container.decodeIfPresent(String.self, forKey: .selfWikilink)
        needsAttribution = try container.decode(Bool.self, forKey: .needsAttribution)
        needsCalendarEnrichment = try container.decode(Bool.self, forKey: .needsCalendarEnrichment)
        needsSummary = try container.decodeIfPresent(Bool.self, forKey: .needsSummary) ?? false
        summary = try container.decode(String.self, forKey: .summary)
        actionItems = try container.decode([QuotedItemArtifact].self, forKey: .actionItems)
        decisions = try container.decode([QuotedItemArtifact].self, forKey: .decisions)
        transcriptSegments = try container.decode([TranscriptSegmentArtifact].self, forKey: .transcriptSegments)
    }
}

/// Maps onto `MeetingForFrontmatter`'s `QuotedItem`
/// (`Sources/Persist/MeetingForFrontmatter.swift:67-75`) — a separate type
/// because the cache-artifact dialect and the renderer's own input contract
/// are independent boundaries that happen to share a shape today.
public struct QuotedItemArtifact: Codable, Equatable, Sendable {
    public let text: String
    public let quote: String

    public init(text: String, quote: String) {
        self.text = text
        self.quote = quote
    }
}

/// Maps onto `MeetingForFrontmatter`'s `TranscriptSegment`
/// (`Sources/Persist/MeetingForFrontmatter.swift:78-86`).
public struct TranscriptSegmentArtifact: Codable, Equatable, Sendable {
    public let speaker: String
    public let text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}
