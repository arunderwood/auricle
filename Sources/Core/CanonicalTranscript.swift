public struct CanonicalTranscript: Codable, Sendable, Equatable {
    public let text: String
    public let utterances: [Utterance]

    public var utteranceCount: Int {
        utterances.count
    }

    /// Every case maps to itself here, but the enum still has to be explicit
    /// (AR-PAT-2): a type's JSON dialect must be readable from its own
    /// declaration, so this marks the cache-artifact (snake_case) dialect
    /// regardless of whether any individual field currently needs renaming.
    enum CodingKeys: String, CodingKey {
        case text
        case utterances
    }

    public init(text: String, utterances: [Utterance]) {
        self.text = text
        self.utterances = utterances
    }

    public struct Utterance: Sendable, Equatable {
        public let speakerLabel: String
        /// UTF-8 byte offset into `CanonicalTranscript.text`, inclusive —
        /// the same convention `GroundingPointer` uses.
        ///
        /// The `[start, end)` range covers the whole line, including the
        /// leading `<speakerLabel>: ` prefix, so `start` is the offset of the
        /// label's first byte and the range slices the utterance exactly as
        /// the summarizer reads it. Consumers that show the speaker
        /// separately drop that one prefix themselves.
        public let start: Int
        /// UTF-8 byte offset into `CanonicalTranscript.text`, exclusive.
        public let end: Int

        public init(speakerLabel: String, start: Int, end: Int) {
            self.speakerLabel = speakerLabel
            self.start = start
            self.end = end
        }
    }
}

extension CanonicalTranscript.Utterance: Codable {
    private enum CodingKeys: String, CodingKey {
        case speakerLabel = "speaker_label"
        case start
        case end
    }
}
