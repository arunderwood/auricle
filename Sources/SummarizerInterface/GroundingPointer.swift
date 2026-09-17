/// Normalized pointer into the canonical transcript. Both Citations and
/// substring strategies resolve to this shape at the validator boundary; the
/// persist stage and renderer never see anything else.
public struct GroundingPointer: Codable, Sendable, Equatable {
    /// UTF-8 byte offsets into the canonical transcript — auricle's own
    /// convention, not an echo of Anthropic's block-index units. `transcriptEnd`
    /// is exclusive.
    public let transcriptStart: Int
    public let transcriptEnd: Int
    /// Telemetry only. Never branch downstream behavior on this value.
    public let sourceMethod: GroundingMethod

    enum CodingKeys: String, CodingKey {
        case transcriptStart = "transcript_start"
        case transcriptEnd = "transcript_end"
        case sourceMethod = "source_method"
    }

    public init(transcriptStart: Int, transcriptEnd: Int, sourceMethod: GroundingMethod) {
        self.transcriptStart = transcriptStart
        self.transcriptEnd = transcriptEnd
        self.sourceMethod = sourceMethod
    }
}
