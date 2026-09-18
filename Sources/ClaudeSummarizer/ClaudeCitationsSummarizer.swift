import Core
import Foundation
import Summarize
import SummarizerInterface

/// One `action_items`/`decisions` entry the citations prompt requests:
/// display text plus the model's own `source_block_index`. Decoded because
/// the item JSON shape is load-bearing (architecture.md Decision 3.2: without
/// this field Anthropic attaches zero real citations to any item), but never
/// consulted for grounding — a cross-check, never the grounding. Declared
/// alongside, not nested inside, `ClaudeCitationsModelAnswer`: this
/// codebase's nesting-depth rule caps types at one level deep.
private struct ClaudeCitationsModelAnswerItem: Decodable {
    let text: String
    let sourceBlockIndex: Int

    enum CodingKeys: String, CodingKey {
        case text
        case sourceBlockIndex = "source_block_index"
    }
}

/// The Messages API answer shape the citations prompt requests: a
/// one-paragraph summary plus `action_items`/`decisions` arrays. Kept
/// private: no caller outside this file has a reason to see the model's
/// answer before it's been grounded and turned into `GroundedItem`s.
private struct ClaudeCitationsModelAnswer: Decodable {
    let summary: String
    let actionItems: [ClaudeCitationsModelAnswerItem]
    let decisions: [ClaudeCitationsModelAnswerItem]

    enum CodingKeys: String, CodingKey {
        case summary
        case actionItems = "action_items"
        case decisions
    }
}

/// The MVP default grounding strategy (Decision 3.6): submits the transcript
/// as an Anthropic Citations document — one content block per utterance —
/// and maps each returned `content_block_location` back to that utterance's
/// own `[start, end)` byte range via `CitationGroundingValidator`. Shares
/// `SummarizationPromptBuilder` with `ClaudeSubstringSummarizer` so the two
/// strategies' prompts can never drift apart (Decision 3.2).
public struct ClaudeCitationsSummarizer: SummarizerStrategy {
    /// Anthropic's Messages API requires `max_tokens`; no AC or architecture
    /// decision fixes a value for this call shape yet, so this is a
    /// documented stand-in until a real token-budget story lands — the same
    /// posture Story 3.3's rate table and `ClaudeSubstringSummarizer`'s own
    /// `maxTokens` already established.
    private static let maxTokens = 4096
    /// Anthropic requires a `title` on every document content block; no AC
    /// fixes this value, so it is a fixed, documented stand-in.
    private static let documentTitle = "Meeting transcript"
    /// A computed property, not a stored `static let`: `[String: Any]` isn't
    /// `Sendable`, and Swift 6.3's strict concurrency checking flags any
    /// stored global of a non-`Sendable` type as possibly-shared mutable
    /// state even when, as here, it's never mutated after creation.
    private static var cacheControl: [String: Any] {
        ["type": "ephemeral"]
    }

    /// Citations is all-or-nothing: any grounding failure throws instead of
    /// dropping the item, so a successful return has nothing to count.
    private static let quoteValidationDropCount = 0

    private let httpClient: AnthropicHTTPClient
    /// `static`, not an instance property: `groundedSummary` and
    /// `citationBlockLocation` are `static func`s and need this too, and
    /// `Log` carries no per-instance state to justify two copies.
    private static let log = Log(category: "claude-summarizer")

    public init(httpClient: AnthropicHTTPClient = AnthropicHTTPClient()) {
        self.httpClient = httpClient
    }

    public func summarize(
        transcript: CanonicalTranscript,
        glossary: Glossary,
        config: SummarizerConfig,
    ) async throws -> SummaryWithGrounding {
        // `attendees: []`/`promptDir: nil` always: neither channel exists on
        // this fixed protocol signature or on `SummarizerConfig` today — the
        // stage entry point (Story 3.7) threads real attendee data and
        // `--prompt-dir` resolution in, not a strategy.
        let prompt = try SummarizationPromptBuilder.build(
            transcript: transcript,
            glossary: glossary,
            attendees: [],
            mode: .citations,
            promptDir: nil,
        )

        let requestBody = try Self.buildRequestBody(prompt: prompt, transcript: transcript, modelIdentifier: config.modelIdentifier)
        let response = try await httpClient.send(AnthropicRequest(body: requestBody))

        let blocks: [[String: Any]]
        let answer: ClaudeCitationsModelAnswer
        do {
            blocks = try Self.parseContentBlocks(response.content)
            answer = try Self.decodeModelAnswer(from: blocks)
        } catch {
            // The transport layer already logged the HTTP-level outcome; a
            // decode failure happens after that, so without this the only
            // trace of a malformed 200 response is the thrown error itself.
            Self.log.warn("citations model answer failed to decode", [:])
            throw error
        }

        return try Self.groundedSummary(from: answer, blocks: blocks, response: response, transcript: transcript)
    }

    /// Grounds every decoded item against the response's citation-bearing
    /// blocks and assembles the final `SummaryWithGrounding`. Split out of
    /// `summarize()` to keep that function's own body short; the
    /// all-or-nothing contract is unchanged — Citations is all-or-nothing
    /// per call, unlike substring's per-item drop-and-continue: any failure
    /// below aborts the whole call rather than returning a partial result.
    /// A fresh call is what `SummarizerOrchestrator` (Story 3.6) retries via
    /// fallback.
    private static func groundedSummary(
        from answer: ClaudeCitationsModelAnswer,
        blocks: [[String: Any]],
        response: AnthropicResponse,
        transcript: CanonicalTranscript,
    ) throws -> SummaryWithGrounding {
        let itemCount = answer.actionItems.count + answer.decisions.count
        guard itemCount > 0 else {
            return SummaryWithGrounding(
                schemaVersion: 1,
                summary: answer.summary,
                actionItems: [],
                decisions: [],
                groundingMethod: .citations,
                cost: cost(from: response),
                quoteValidationDropCount: quoteValidationDropCount,
            )
        }

        let citations = citationBearingBlockCitations(in: blocks)
        guard !citations.isEmpty else {
            log.warn("citations unavailable in response", [:])
            throw SummarizerError.citationsUnavailable
        }
        guard citations.count == itemCount else {
            log.warn("citation count does not match item count", [:])
            throw SummarizerError.malformedResponse
        }

        let groundedActionItems = try groundedItems(
            from: answer.actionItems,
            citations: citations.prefix(answer.actionItems.count),
            transcript: transcript,
        )
        let groundedDecisions = try groundedItems(
            from: answer.decisions,
            citations: citations.suffix(answer.decisions.count),
            transcript: transcript,
        )

        return SummaryWithGrounding(
            schemaVersion: 1,
            summary: answer.summary,
            actionItems: groundedActionItems,
            decisions: groundedDecisions,
            groundingMethod: .citations,
            cost: cost(from: response),
            quoteValidationDropCount: quoteValidationDropCount,
        )
    }

    /// Grounds a matching declaration-order slice of `citations` against
    /// `items` — the positional zip Decision 3.2 documents: citation-bearing
    /// blocks appear in the response in the same left-to-right order the
    /// JSON schema declares (`action_items` fully emitted before
    /// `decisions`, items in array order within each).
    private static func groundedItems(
        from items: [ClaudeCitationsModelAnswerItem],
        citations: some Sequence<[String: Any]>,
        transcript: CanonicalTranscript,
    ) throws -> [GroundedItem] {
        try zip(items, citations).map { item, citation in
            let location = try citationBlockLocation(from: citation)
            let pointer = try CitationGroundingValidator.validate(citation: location, in: transcript)
            return GroundedItem(text: item.text, grounding: pointer)
        }
    }

    private static func citationBlockLocation(from citation: [String: Any]) throws -> CitationBlockLocation {
        guard
            let startBlockIndex = citation["start_block_index"] as? Int,
            let endBlockIndex = citation["end_block_index"] as? Int
        else {
            log.warn("citation missing start/end block index", [:])
            throw SummarizerError.malformedResponse
        }
        return CitationBlockLocation(startBlockIndex: startBlockIndex, endBlockIndex: endBlockIndex)
    }

    private static func cost(from response: AnthropicResponse) -> SummarizerCost {
        SummarizerCost(
            inputTokens: response.usage.inputTokens,
            outputTokens: response.usage.outputTokens,
            thinkingTokens: response.thinkingTokens,
            costUSD: response.costUSD,
        )
    }

    /// One text block per `transcript.utterances`, sliced by that utterance's
    /// own UTF-8 byte `[start, end)` range — the document content Anthropic's
    /// Citations API segments and returns `content_block_location` indices
    /// against. Exposed at `internal` (not `private`) visibility so
    /// `CanonicalTranscriptContractTests` can call this exact segmentation
    /// code via `@testable import` instead of re-deriving an equivalent
    /// slice independently (Decision 3.4's canonicalization invariant).
    static func contentBlockTexts(for transcript: CanonicalTranscript) -> [String] {
        let bytes = Array(transcript.text.utf8)
        return transcript.utterances.map { utterance in
            // An out-of-bounds or inverted range would trap on the subscript
            // below rather than fail gracefully, so it's checked before
            // slicing — the same non-crashing posture the `?? ""` fallback
            // on the next line already holds for a decode failure.
            guard
                utterance.start >= 0,
                utterance.end <= bytes.count,
                utterance.start <= utterance.end
            else {
                return ""
            }
            // `?? ""` never actually fires: a byte range sliced from a Swift
            // `String`'s own UTF-8 view at a utterance's `[start, end)`
            // boundary is always valid UTF-8 when that boundary sits on a
            // scalar boundary — the same invariant `SubstringGroundingValidator`
            // relies on for its own offsets.
            return String(bytes: bytes[utterance.start ..< utterance.end], encoding: .utf8) ?? ""
        }
    }

    /// Builds the Messages API request body directly via `JSONSerialization`
    /// (matching `ClaudeSubstringSummarizer`'s own style), with the
    /// transcript submitted as a custom content document — one block per
    /// utterance — instead of a plain text block. No `output_config.format`
    /// anywhere: Anthropic returns 400 when structured-JSON-by-format is
    /// combined with `citations.enabled: true` (Decision 3.2).
    private static func buildRequestBody(
        prompt: SummarizationPrompt,
        transcript: CanonicalTranscript,
        modelIdentifier: String,
    ) throws -> Data {
        var contentBlocks: [[String: Any]] = []
        var lastCacheableBlockIndex: Int?

        if !prompt.glossary.text.isEmpty {
            contentBlocks.append(["type": "text", "text": prompt.glossary.text])
            lastCacheableBlockIndex = contentBlocks.count - 1
        }
        if !prompt.attendeeContext.text.isEmpty {
            contentBlocks.append(["type": "text", "text": prompt.attendeeContext.text])
            lastCacheableBlockIndex = contentBlocks.count - 1
        }
        // Anthropic's cache breakpoint marks a prefix boundary, so only the
        // last non-empty cacheable block before the document carries
        // `cache_control` — marking every cacheable block individually would
        // be redundant (Decision 3.5's caching table).
        if let lastCacheableBlockIndex {
            contentBlocks[lastCacheableBlockIndex]["cache_control"] = cacheControl
        }
        // The document is unique per meeting and never cached.
        contentBlocks.append([
            "type": "document",
            "source": [
                "type": "content",
                "content": contentBlockTexts(for: transcript).map { ["type": "text", "text": $0] },
            ],
            "title": documentTitle,
            "citations": ["enabled": true],
        ])

        let body: [String: Any] = [
            "model": modelIdentifier,
            "max_tokens": maxTokens,
            "system": [
                ["type": "text", "text": prompt.system.text, "cache_control": cacheControl],
            ],
            "messages": [
                ["role": "user", "content": contentBlocks],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// `response.content` is the opaque, re-serialized `content` array
    /// `AnthropicHTTPClient` never inspects. Parsed once, here, into raw
    /// blocks: `decodeModelAnswer` reads every block's `text`;
    /// `citationBearingBlockCitations` separately reads every block's
    /// `citations` — the same ordered array serves both reads.
    private static func parseContentBlocks(_ content: Data) throws -> [[String: Any]] {
        guard let blocks = (try? JSONSerialization.jsonObject(with: content)) as? [[String: Any]] else {
            throw SummarizerError.malformedResponse
        }
        return blocks
    }

    private static func decodeModelAnswer(from blocks: [[String: Any]]) throws -> ClaudeCitationsModelAnswer {
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else {
            throw SummarizerError.malformedResponse
        }

        guard let answer = try? JSONDecoder().decode(ClaudeCitationsModelAnswer.self, from: Data(text.utf8)) else {
            throw SummarizerError.malformedResponse
        }
        return answer
    }

    /// The first citation object on each response block whose `citations`
    /// array is non-empty, in block order — the positional association
    /// architecture.md documents: "the cited response block *is* the item's
    /// text value." The model's own `source_block_index` (decoded above) is
    /// a cross-check never consulted here, per Decision 3.2. Never logs
    /// `cited_text` or any other citation-dict field: those carry transcript
    /// content.
    private static func citationBearingBlockCitations(in blocks: [[String: Any]]) -> [[String: Any]] {
        blocks.compactMap { block in
            (block["citations"] as? [[String: Any]])?.first
        }
    }
}
