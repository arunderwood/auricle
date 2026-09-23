import Attribute
import Core
import SummarizerInterface

/// Maps the summarize stage's inputs and the summarizer's output into the
/// `summary.json` contract. Every piece of transcript text in the artifact —
/// quotes and segment text alike — is the exact UTF-8 byte slice of the one
/// decoded `CanonicalTranscript.text`, so the note shows what was said, never
/// a paraphrase of it.
enum SummaryArtifactMapper {
    /// One segment per utterance, in transcript order. `speaker` is the
    /// attributed `[[Name]]` wikilink and `[[Speaker_N]]` otherwise, so an
    /// unattributed speaker is still a valid, resolvable link. It comes from
    /// `utteranceSpeakers` (the diarization join) where that has one for the
    /// utterance, because the transcript labels every utterance alike, and
    /// from `speakers[utterance.speakerLabel]` where it has none. `text` is the utterance without its leading
    /// `<speakerLabel>: ` (see `CanonicalTranscript.Utterance`), because the
    /// renderer prints the speaker itself.
    static func transcriptSegments(
        of transcript: CanonicalTranscript,
        transcriptBytes: [UInt8],
        speakers: [String: String]?,
        utteranceSpeakers: [String?]? = nil,
    ) throws -> [TranscriptSegmentArtifact] {
        try transcript.utterances.enumerated().map { index, utterance in
            let start = startAfterLabel(of: utterance, in: transcriptBytes)
            guard case let .success(text) = TranscriptSlicer.slice(start: start, end: utterance.end, of: transcriptBytes) else {
                throw SummarizeStageError.segmentExtractionFailed
            }
            let speaker = speakerLink(for: utterance, at: index, speakers: speakers, utteranceSpeakers: utteranceSpeakers)
            return TranscriptSegmentArtifact(speaker: speaker.link, text: text)
        }
    }

    /// Where the utterance's text begins. Only this utterance's own
    /// `<speakerLabel>: ` at the head of its range is skipped, and only once,
    /// so a label-shaped string later in the text, another speaker's name, or
    /// a repeat of this label is left alone. Compared as bytes, not
    /// `Character`s, so a combining mark after the space cannot hide the
    /// prefix. A range that does not begin with the label is returned as is.
    /// An out-of-range utterance is also returned as is, for the slicer to
    /// reject.
    private static func startAfterLabel(of utterance: CanonicalTranscript.Utterance, in bytes: [UInt8]) -> Int {
        guard utterance.start >= 0, utterance.start <= utterance.end, utterance.end <= bytes.count else {
            return utterance.start
        }
        let label = Array(utterance.speakerLabel.utf8) + [UInt8(ascii: ":")]
        let head = bytes[utterance.start ..< utterance.end]
        guard head.starts(with: label) else { return utterance.start }
        let afterColon = utterance.start + label.count
        if afterColon == utterance.end {
            return afterColon
        }
        return bytes[afterColon] == UInt8(ascii: " ") ? afterColon + 1 : utterance.start
    }

    /// The link an utterance is shown under, and whether it names a person.
    /// A `Speaker_N` value, wherever it comes from, names nobody.
    private static func speakerLink(
        for utterance: CanonicalTranscript.Utterance,
        at index: Int,
        speakers: [String: String]?,
        utteranceSpeakers: [String?]?,
    ) -> (link: String, named: Bool) {
        let joined = utteranceSpeakers.flatMap { $0.indices.contains(index) ? $0[index] : nil }
        let value = joined ?? speakers?[utterance.speakerLabel] ?? utterance.speakerLabel
        if UtteranceSpeakers.isPlaceholder(value) {
            return ("[[\(value)]]", false)
        }
        return (value, true)
    }

    /// True unless attribution exists and names the speaker of every
    /// utterance. A partly named transcript still needs attribution.
    static func needsAttribution(transcript: CanonicalTranscript, speakers: [String: String]?, utteranceSpeakers: [String?]? = nil) -> Bool {
        guard speakers != nil else { return true }
        return transcript.utterances.enumerated().contains { index, utterance in
            !speakerLink(for: utterance, at: index, speakers: speakers, utteranceSpeakers: utteranceSpeakers).named
        }
    }

    /// The artifact for one run. Without a `match` it is the unenriched
    /// variant: `title` (the generic capture-time title) stands, there is no
    /// event title, no attendees and no self link, and `needsCalendarEnrichment`
    /// is set so persist tags the note for a later backfill. With one, the
    /// event supplies all four and the tag is not set.
    ///
    /// `configuredSelfWikilink` is the user's own `self.wikilink` from config;
    /// when it normalizes it wins over the calendar's self identity, with or
    /// without a match, because it is the user's explicit statement of who
    /// they are. One that does not normalize is ignored.
    static func artifact(
        title: String,
        match: CalendarEnrichment.Match? = nil,
        configuredSelfWikilink: String? = nil,
        grounded: SummaryWithGrounding,
        transcriptSegments: [TranscriptSegmentArtifact],
        needsAttribution: Bool,
        transcriptBytes: [UInt8],
    ) throws -> SummaryArtifact {
        let configuredSelfWikilink = normalized(configuredSelfWikilink)
        return try SummaryArtifact(
            title: match?.title ?? title,
            calendarEventTitle: match?.title,
            attendees: attendees(of: match, configuredSelfWikilink: configuredSelfWikilink),
            selfWikilink: configuredSelfWikilink ?? match?.selfWikilink,
            needsAttribution: needsAttribution,
            needsCalendarEnrichment: match == nil,
            summary: grounded.summary,
            actionItems: quotedItems(grounded.actionItems, transcriptBytes: transcriptBytes),
            decisions: quotedItems(grounded.decisions, transcriptBytes: transcriptBytes),
            transcriptSegments: transcriptSegments,
        )
    }

    /// The artifact a failed summarize leaves under `--publish-anyway`: every
    /// field the success path builds from the stage's own inputs, and none of
    /// the summarizer's. Persist renders it as the `published_partial` note.
    static func stubArtifact(
        title: String,
        match: CalendarEnrichment.Match? = nil,
        configuredSelfWikilink: String? = nil,
        transcriptSegments: [TranscriptSegmentArtifact],
        needsAttribution: Bool,
    ) -> SummaryArtifact {
        let configuredSelfWikilink = normalized(configuredSelfWikilink)
        return SummaryArtifact(
            title: match?.title ?? title,
            calendarEventTitle: match?.title,
            attendees: attendees(of: match, configuredSelfWikilink: configuredSelfWikilink),
            selfWikilink: configuredSelfWikilink ?? match?.selfWikilink,
            needsAttribution: needsAttribution,
            needsCalendarEnrichment: match == nil,
            needsSummary: true,
            summary: "",
            actionItems: [],
            decisions: [],
            transcriptSegments: transcriptSegments,
        )
    }

    private static func normalized(_ configuredSelfWikilink: String?) -> String? {
        configuredSelfWikilink.flatMap { try? SelfWikilink.normalized($0) }
    }

    /// The event's attendee links, with the calendar's self link replaced by
    /// the configured one when both exist: persist recognizes the user among
    /// the attendees by `selfWikilink`, so the two must name the same page.
    private static func attendees(of match: CalendarEnrichment.Match?, configuredSelfWikilink: String?) -> [String] {
        let attendees = match?.attendeeWikilinks ?? []
        guard let configuredSelfWikilink, let calendarSelf = match?.selfWikilink else { return attendees }
        return attendees.map { $0 == calendarSelf ? configuredSelfWikilink : $0 }
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
