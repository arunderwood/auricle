import Core

/// The one `SummaryArtifact` → `MeetingForFrontmatter` mapping. `PersistStage`
/// and any offline caller that renders the shipped note go through here, so a
/// field added to the artifact cannot reach one note shape and miss the other.
public enum SummaryArtifactFrontmatter {
    public static func meeting(
        _ artifact: SummaryArtifact,
        meetingID: MeetingID,
        date: String,
        supersedes: String?,
    ) -> MeetingForFrontmatter {
        MeetingForFrontmatter(
            meetingID: meetingID,
            title: artifact.title,
            date: date,
            attendees: artifact.attendees,
            schemaVersion: FrontmatterSchema.current,
            supersedes: supersedes,
            needsAttribution: artifact.needsAttribution,
            needsCalendarEnrichment: artifact.needsCalendarEnrichment,
            needsSummary: artifact.needsSummary,
            summary: artifact.summary,
            actionItems: artifact.actionItems.map { QuotedItem(text: $0.text, quote: $0.quote) },
            decisions: artifact.decisions.map { QuotedItem(text: $0.text, quote: $0.quote) },
            transcriptSegments: artifact.transcriptSegments.map { TranscriptSegment(speaker: $0.speaker, text: $0.text) },
        )
    }
}
