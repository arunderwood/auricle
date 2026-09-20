import Core

/// The two immutable artifacts a diarization review reads. A named struct
/// because a tuple cannot be `Codable`.
public struct DiarizationReviewInput<Diarization: Codable & Sendable>: Codable, Sendable {
    public let transcript: CanonicalTranscript
    public let diarization: Diarization

    enum CodingKeys: String, CodingKey {
        case transcript
        case diarization
    }

    public init(transcript: CanonicalTranscript, diarization: Diarization) {
        self.transcript = transcript
        self.diarization = diarization
    }
}

/// Phase 1 of the reviewer family: flags segments whose speaker labels look
/// wrong. `Diarization` is the type of `diarization.json`; the diarizer's
/// interface owns that type, and a concrete reviewer binds it.
public protocol DiarizationReviewerStrategy: AIReviewerStrategy
    where Input == DiarizationReviewInput<Diarization>, Output == DiarizationSuggestion {
    associatedtype Diarization: Codable & Sendable
}
