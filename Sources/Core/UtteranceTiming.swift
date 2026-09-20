/// Where one transcript utterance sits in the audio, in seconds from its
/// start. `index` is the utterance's position in `CanonicalTranscript.utterances`,
/// so a consumer can join timing to text without re-deriving offsets.
public struct UtteranceTiming: Sendable, Equatable {
    public let index: Int
    public let startSeconds: Double
    public let endSeconds: Double

    public init(index: Int, startSeconds: Double, endSeconds: Double) {
        self.index = index
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}
