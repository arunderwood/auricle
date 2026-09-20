import Core
import Foundation

/// Turns one audio file into the speaker segments the attribution sheet and
/// its snippets are built from. The strategy sees the transcript and its
/// timing only to relate segments to utterances, never the meeting record
/// (AR-PAT-7 interface segregation).
///
/// An implementation builds its result with `DiarizationArtifactBuilder`, so
/// labels, ids, overlap and the utterance link are the same whichever engine
/// produced the raw segments.
public protocol DiarizerStrategy: Sendable {
    func diarize(
        transcript: CanonicalTranscript,
        utteranceTimings: [UtteranceTiming],
        audio: URL,
        config: DiarizerConfig,
    ) async throws -> DiarizationArtifact
}
