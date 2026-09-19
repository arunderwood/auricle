import Core
import Foundation

/// Turns one audio file into the transcript every later stage reads. The
/// strategy sees only the audio and its config, never the meeting record
/// (AR-PAT-7 interface segregation).
///
/// An implementation is expected to build the returned transcript through
/// `CanonicalTranscriptBuilder`, which is what makes its text and byte ranges
/// meet the transcript contract. The protocol does not enforce that:
/// `CanonicalTranscript.init` is public, so a strategy that assembles one by
/// hand can return one that breaks the contract. The transcript carries no
/// diarization: every utterance a transcriber returns is attributed to one
/// placeholder speaker until a diarization stage says otherwise.
public protocol TranscriberStrategy: Sendable {
    func transcribe(audio: URL, config: TranscriberConfig) async throws -> CanonicalTranscript
}
