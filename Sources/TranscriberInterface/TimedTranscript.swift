import Core

/// A transcript and where each of its utterances sits in the audio. A later
/// stage that must relate the transcript to something measured against the
/// audio (which speaker was talking) needs the timing, and the immutable
/// `transcript.json` does not carry it.
public struct TimedTranscript: Sendable, Equatable {
    public let transcript: CanonicalTranscript
    /// One entry per utterance the transcript kept, or empty when the
    /// strategy cannot report timing.
    public let utteranceTimings: [UtteranceTiming]

    public init(transcript: CanonicalTranscript, utteranceTimings: [UtteranceTiming] = []) {
        self.transcript = transcript
        self.utteranceTimings = utteranceTimings
    }
}
