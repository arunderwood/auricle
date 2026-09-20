/// The base of the reviewer family. A reviewer reads immutable cache
/// artifacts and answers with suggestions; it never edits the artifacts it
/// read. The jargon-correction sibling does not conform: it takes a summary
/// and a glossary and needs no model call.
public protocol AIReviewerStrategy: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Suggestion & Equatable

    func review(input: Input, config: AIReviewerConfig) async throws -> AIReviewerResult<Output>
}
