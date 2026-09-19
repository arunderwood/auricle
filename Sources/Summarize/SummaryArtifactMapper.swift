import Core
import SummarizerInterface

/// Maps the summarize stage's inputs and the summarizer's output into the
/// `summary.json` contract. Every piece of transcript text in the artifact —
/// quotes and segment text alike — is the exact UTF-8 byte slice of the one
/// decoded `CanonicalTranscript.text`, so the note shows what was said, never
/// a paraphrase of it.
enum SummaryArtifactMapper {
    /// One segment per utterance, in transcript order. `speaker` is the
    /// attributed `[[Name]]` wikilink where `speakers` has one and
    /// `[[<speakerLabel>]]` otherwise, so an unattributed speaker is still a
    /// valid, resolvable link.
    static func transcriptSegments(
        of transcript: CanonicalTranscript,
        transcriptBytes: [UInt8],
        speakers: [String: String]?,
    ) throws -> [TranscriptSegmentArtifact] {
        try transcript.utterances.map { utterance in
            guard case let .success(text) = TranscriptSlicer.slice(start: utterance.start, end: utterance.end, of: transcriptBytes) else {
                throw SummarizeStageError.segmentExtractionFailed
            }
            let speaker = speakers?[utterance.speakerLabel] ?? "[[\(utterance.speakerLabel)]]"
            return TranscriptSegmentArtifact(speaker: speaker, text: text)
        }
    }

    /// True unless attribution exists and names every distinct speaker in the
    /// transcript. A partly named transcript still needs attribution.
    static func needsAttribution(transcript: CanonicalTranscript, speakers: [String: String]?) -> Bool {
        guard let speakers else { return true }
        let labels = Set(transcript.utterances.map(\.speakerLabel))
        return !labels.isSubset(of: speakers.keys)
    }

    /// The artifact for one run. Without a `match` it is the unenriched
    /// variant: `title` (the generic capture-time title) stands, there is no
    /// event title, no attendees and no self link, and `needsCalendarEnrichment`
    /// is set so persist tags the note for a later backfill. With one, the
    /// event supplies all four and the tag is not set.
    static func artifact(
        title: String,
        match: CalendarEnrichment.Match? = nil,
        grounded: SummaryWithGrounding,
        transcriptSegments: [TranscriptSegmentArtifact],
        needsAttribution: Bool,
        transcriptBytes: [UInt8],
    ) throws -> SummaryArtifact {
        try SummaryArtifact(
            title: match?.title ?? title,
            calendarEventTitle: match?.title,
            attendees: match?.attendeeWikilinks ?? [],
            selfWikilink: match?.selfWikilink,
            needsAttribution: needsAttribution,
            needsCalendarEnrichment: match == nil,
            summary: grounded.summary,
            actionItems: quotedItems(grounded.actionItems, transcriptBytes: transcriptBytes),
            decisions: quotedItems(grounded.decisions, transcriptBytes: transcriptBytes),
            transcriptSegments: transcriptSegments,
        )
    }

    private static func quotedItems(_ items: [GroundedItem], transcriptBytes: [UInt8]) throws -> [QuotedItemArtifact] {
        try items.map { item in
            guard case let .success(quote) = TranscriptSlicer.slice(item.grounding, of: transcriptBytes) else {
                throw SummarizeStageError.quoteExtractionFailed
            }
            return QuotedItemArtifact(text: item.text, quote: quote)
        }
    }
}
