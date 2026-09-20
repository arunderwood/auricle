import Core

public struct TranscriptionReviewInput: Codable, Sendable {
    public let transcript: CanonicalTranscript
    public let audio: AudioFingerprint

    enum CodingKeys: String, CodingKey {
        case transcript
        case audio
    }

    public init(transcript: CanonicalTranscript, audio: AudioFingerprint) {
        self.transcript = transcript
        self.audio = audio
    }
}

/// Phase 3 of the reviewer family. Declared so its slot exists; no
/// conformer ships until the transcription-review story.
public protocol TranscriptionReviewerStrategy: AIReviewerStrategy
    where Input == TranscriptionReviewInput, Output == TranscriptionSuggestion {}
