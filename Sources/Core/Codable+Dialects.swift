import Foundation

// The codebase uses two JSON dialects (AR-PAT-2), chosen per type, not per
// decoder: `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` is
// deliberately not used, because it is invisible at the call site and
// round-trips unreliably for keys with digits or acronyms. Which dialect a
// type belongs to must be readable from the type's own declaration.
//
// - Cache-dir artifacts, vault frontmatter, `stage_events.metadata_json`,
//   and notification payloads are snake_case: declare an explicit
//   `CodingKeys: String, CodingKey` mapping each property to its snake_case
//   JSON key, as `CacheArtifactDialectExample` does below.
// - CLI `--json` output and structured errors are camelCase: rely on
//   `Codable`'s default synthesis and declare no `CodingKeys` at all, as
//   `CLIOutputDialectExample` does below.
//
// Every JSON-shaped contract type needs a round-trip (encode -> decode ->
// equality) test; these two examples are exercised by `DialectsTests.swift`.

struct CacheArtifactDialectExample: Codable, Equatable {
    let meetingId: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case createdAt = "created_at"
    }
}

struct CLIOutputDialectExample: Codable, Equatable {
    let meetingId: String
    let createdAt: Date
}
