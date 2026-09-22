import Core
import SummarizerInterface

/// Builds a `SummaryArtifact` from a transcript and a summarizer result alone,
/// with no stage, no cache and no attribution — the seam an offline harness
/// needs to render the shipped note from a frozen fixture.
///
/// `SummaryArtifactMapper` stays internal: the artifact contract a caller
/// outside this module may reach is exactly this one entry point, not the
/// mapper's four-parameter surface.
public enum OfflineSummaryArtifact {
    /// No attribution is available offline, so every utterance keeps its
    /// `Speaker_N` label and the artifact is marked as needing attribution —
    /// the same shape the pipeline produces before anyone names a speaker.
    public static func artifact(
        title: String,
        transcript: CanonicalTranscript,
        grounded: SummaryWithGrounding,
    ) throws -> SummaryArtifact {
        let transcriptBytes = Array(transcript.text.utf8)
        return try SummaryArtifactMapper.artifact(
            title: title,
            grounded: grounded,
            transcriptSegments: SummaryArtifactMapper.transcriptSegments(
                of: transcript,
                transcriptBytes: transcriptBytes,
                speakers: nil,
            ),
            needsAttribution: SummaryArtifactMapper.needsAttribution(transcript: transcript, speakers: nil),
            transcriptBytes: transcriptBytes,
        )
    }
}
