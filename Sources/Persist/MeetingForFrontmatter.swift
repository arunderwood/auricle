import Core

/// The sole input to `FrontmatterRenderer.render(meeting:)`. Every field
/// arrives pre-resolved by the caller — titles, wikilinks, and dates are
/// never derived here.
public struct MeetingForFrontmatter: Sendable, Equatable {
    public let meetingID: MeetingID
    public let title: String
    /// Already formatted "YYYY-MM-DD".
    public let date: String
    /// Already-wikilinked, e.g. `"[[Ben]]"` or `"[[Speaker_1]]"`.
    public let attendees: [String]
    public let schemaVersion: Int
    /// Filename of the note this publish supersedes, re-published variant only.
    public let supersedes: String?
    public let needsAttribution: Bool
    public let needsCalendarEnrichment: Bool
    /// The `published_partial` variant: adds the `auricle/needs-summary` tag
    /// and leaves out the Action Items and Decisions sections, which an absent
    /// summary cannot fill.
    public let needsSummary: Bool
    /// One paragraph, already wikilinked.
    public let summary: String
    public let actionItems: [QuotedItem]
    public let decisions: [QuotedItem]
    public let transcriptSegments: [TranscriptSegment]

    public init(
        meetingID: MeetingID,
        title: String,
        date: String,
        attendees: [String],
        schemaVersion: Int,
        supersedes: String?,
        needsAttribution: Bool,
        needsCalendarEnrichment: Bool,
        needsSummary: Bool = false,
        summary: String,
        actionItems: [QuotedItem],
        decisions: [QuotedItem],
        transcriptSegments: [TranscriptSegment],
    ) {
        self.meetingID = meetingID
        self.title = title
        self.date = date
        self.attendees = attendees
        self.schemaVersion = schemaVersion
        self.supersedes = supersedes
        self.needsAttribution = needsAttribution
        self.needsCalendarEnrichment = needsCalendarEnrichment
        self.needsSummary = needsSummary
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.transcriptSegments = transcriptSegments
    }
}

/// A quote-grounded action item or decision: the resolved bullet text plus
/// the verbatim source quote rendered beneath it as a blockquote.
public struct QuotedItem: Sendable, Equatable {
    public let text: String
    public let quote: String

    public init(text: String, quote: String) {
        self.text = text
        self.quote = quote
    }
}

/// One turn of transcript, already attributed to a wikilinked speaker.
public struct TranscriptSegment: Sendable, Equatable {
    public let speaker: String
    public let text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}
