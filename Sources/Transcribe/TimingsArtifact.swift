import Core

/// One utterance's timing in the cache-artifact (snake_case) dialect.
/// `UtteranceTiming` is in `Core` and carries no wire format.
struct UtteranceTimingRecord: Codable {
    let index: Int
    let startSeconds: Double
    let endSeconds: Double

    enum CodingKeys: String, CodingKey {
        case index
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

/// `utterance_timings.json`: what a retry needs, beside `transcript.json`, to
/// diarize without transcribing again.
struct TimingsArtifact: Codable {
    let utterances: [UtteranceTimingRecord]

    enum CodingKeys: String, CodingKey {
        case utterances
    }

    init(timings: [UtteranceTiming]) {
        utterances = timings.map { UtteranceTimingRecord(index: $0.index, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) }
    }

    var timings: [UtteranceTiming] {
        utterances.map { UtteranceTiming(index: $0.index, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds) }
    }
}
