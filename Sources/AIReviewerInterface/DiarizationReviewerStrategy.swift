import Core
import DiarizerInterface

/// The two immutable artifacts a diarization review reads. A named struct
/// because a tuple cannot be `Codable`.
public struct DiarizationReviewInput: Codable, Sendable, Equatable {
    public let transcript: CanonicalTranscript
    public let diarization: DiarizationArtifact

    enum CodingKeys: String, CodingKey {
        case transcript
        case diarization
    }

    public init(transcript: CanonicalTranscript, diarization: DiarizationArtifact) {
        self.transcript = transcript
        self.diarization = diarization
    }
}

/// Phase 1 of the reviewer family: flags segments whose speaker labels look
/// wrong.
public protocol DiarizationReviewerStrategy: AIReviewerStrategy
    where Input == DiarizationReviewInput, Output == DiarizationSuggestion {}
