/// A reviewer's answer: what it flagged, what the call cost, and how many
/// segments it looked at (the trust-calibration footer's "Reviewed N,
/// flagged M").
public struct AIReviewerResult<Output: Suggestion & Equatable>: Codable, Sendable, Equatable {
    public static var currentSchemaVersion: Int {
        1
    }

    public let schemaVersion: Int
    public let suggestions: [Output]
    public let cost: AIReviewerCost
    public let reviewedSegmentCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case suggestions
        case cost
        case reviewedSegmentCount = "reviewed_segment_count"
    }

    public init(
        schemaVersion: Int = AIReviewerResult.currentSchemaVersion,
        suggestions: [Output],
        cost: AIReviewerCost,
        reviewedSegmentCount: Int,
    ) {
        self.schemaVersion = schemaVersion
        self.suggestions = suggestions
        self.cost = cost
        self.reviewedSegmentCount = reviewedSegmentCount
    }
}
