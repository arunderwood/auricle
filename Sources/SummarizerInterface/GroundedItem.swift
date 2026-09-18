public struct GroundedItem: Codable, Sendable, Equatable {
    public let text: String
    public let grounding: GroundingPointer

    enum CodingKeys: String, CodingKey {
        case text
        case grounding
    }

    public init(text: String, grounding: GroundingPointer) {
        self.text = text
        self.grounding = grounding
    }
}
