public struct Glossary: Codable, Sendable, Equatable {
    public let people: [String]
    public let projects: [String]
    public let concepts: [String]
    /// Non-standard vault layouts (no `People`/`Projects` folder convention)
    /// fall back to this single list instead of a failed categorization.
    public let uncategorized: [String]

    /// Every case maps to itself here, but the enum still has to be explicit
    /// (AR-PAT-2): a type's JSON dialect must be readable from its own
    /// declaration, so this marks the cache-artifact (snake_case) dialect
    /// regardless of whether any individual field currently needs renaming.
    enum CodingKeys: String, CodingKey {
        case people
        case projects
        case concepts
        case uncategorized
    }

    public init(
        people: [String] = [],
        projects: [String] = [],
        concepts: [String] = [],
        uncategorized: [String] = [],
    ) {
        self.people = people
        self.projects = projects
        self.concepts = concepts
        self.uncategorized = uncategorized
    }
}
