import Core
import Foundation
import Summarize
import SummarizerInterface

/// One `action_items`/`decisions` entry: free-form display text plus the
/// verbatim quote `SubstringGroundingValidator` resolves against the
/// transcript — the non-Citations grounding contract (Decision 3.2).
/// Declared alongside, not nested inside, `ClaudeSubstringModelAnswer`: this
/// codebase's nesting-depth rule caps types at one level deep.
private struct ClaudeSubstringModelAnswerItem: Decodable {
    let text: String
    let sourceTranscriptQuote: String

    enum CodingKeys: String, CodingKey {
        case text
        case sourceTranscriptQuote = "source_transcript_quote"
    }
}

/// The Messages API answer shape this strategy requests: a one-paragraph
/// summary plus `action_items`/`decisions` arrays. Kept private: no caller
/// outside this file has a reason to see the model's answer before it's
/// been grounded and turned into `GroundedItem`s.
private struct ClaudeSubstringModelAnswer: Decodable {
    let summary: String
    let actionItems: [ClaudeSubstringModelAnswerItem]
    let decisions: [ClaudeSubstringModelAnswerItem]

    enum CodingKeys: String, CodingKey {
        case summary
        case actionItems = "action_items"
        case decisions
    }
}

/// The MVP fallback and v1.1+ local-LLM contract (FR33, Decision 3.3): asks
/// Claude for a free-form `source_transcript_quote` string per item instead
/// of using Anthropic's Citations API, then grounds each quote with a
/// literal substring search via `SubstringGroundingValidator`. Shares
/// `SummarizationPromptBuilder` with `ClaudeCitationsSummarizer` so the two
/// strategies' prompts can never drift apart (Decision 3.2).
public struct ClaudeSubstringSummarizer: SummarizerStrategy {
    /// Anthropic's Messages API requires `max_tokens`; no AC or architecture
    /// decision fixes a value for this call shape yet, so this is a
    /// documented stand-in until a real token-budget story lands — the same
    /// posture Story 3.3 already established for its per-model rate table.
    /// The budget is shared with the model's thinking tokens, and 4096 cut a
    /// long meeting's JSON off mid-string.
    private static let maxTokens = 16384
    /// A computed property, not a stored `static let`: `[String: Any]` isn't
    /// `Sendable`, and Swift 6.3's strict concurrency checking flags any
    /// stored global of a non-`Sendable` type as possibly-shared mutable
    /// state even when, as here, it's never mutated after creation.
    private static var cacheControl: [String: Any] {
        ["type": "ephemeral"]
    }

    private let httpClient: AnthropicHTTPClient
    private let log = Log(category: "claude-summarizer")

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
            mode: .substring,
            promptDir: nil,
        )

        let requestBody = try Self.buildRequestBody(prompt: prompt, modelIdentifier: config.modelIdentifier)
        let response = try await httpClient.send(AnthropicRequest(body: requestBody))
        let answer: ClaudeSubstringModelAnswer
        do {
            answer = try Self.decodeModelAnswer(from: response.content)
        } catch {
            // The transport layer already logged the HTTP-level outcome; a
            // decode failure happens after that, so without this the only
            // trace of a malformed 200 response is the thrown error itself.
            log.warn("substring model answer failed to decode", [:])
            throw error
        }

        let (actionItems, actionItemDrops) = groundedItems(from: answer.actionItems, section: "actionItem", transcript: transcript)
        let (decisions, decisionDrops) = groundedItems(from: answer.decisions, section: "decision", transcript: transcript)
        let dropCount = actionItemDrops + decisionDrops
        log.info("substring quote validation complete", Self.dropCountLogFields(dropCount))

        return SummaryWithGrounding(
            schemaVersion: 1,
            summary: answer.summary,
            actionItems: actionItems,
            decisions: decisions,
            groundingMethod: .substring,
            cost: SummarizerCost(
                inputTokens: response.usage.inputTokens,
                outputTokens: response.usage.outputTokens,
                thinkingTokens: response.thinkingTokens,
                costUSD: response.costUSD,
            ),
            quoteValidationDropCount: dropCount,
        )
    }

    /// Validates every item's quote, dropping (never throwing on) the ones
    /// that don't resolve. A drop is logged by section and index only — the
    /// quote/item text is user content, the same never-log-content posture
    /// `AnthropicHTTPClient` already holds for the response body.
    private func groundedItems(
        from items: [ClaudeSubstringModelAnswerItem],
        section: String,
        transcript: CanonicalTranscript,
    ) -> (items: [GroundedItem], dropCount: Int) {
        var grounded: [GroundedItem] = []
        var dropCount = 0
        for (index, item) in items.enumerated() {
            guard let pointer = SubstringGroundingValidator.validate(quote: item.sourceTranscriptQuote, in: transcript) else {
                log.warn("dropping item: quote not found verbatim in transcript", Self.dropLogFields(section: section, index: index))
                dropCount += 1
                continue
            }
            grounded.append(GroundedItem(text: item.text, grounding: pointer))
        }
        return (grounded, dropCount)
    }

    /// Pure, internally-testable field construction, mirroring how
    /// `AnthropicHTTPClient.redactedLogFields` is tested directly: this
    /// function's parameters carry only a section name and an index, so
    /// the "never logs quote/item text" guarantee holds by construction —
    /// there is no parameter through which either could reach these fields.
    static func dropLogFields(section: String, index: Int) -> [String: LogSensitivity] {
        ["section": .publicSafe(section), "index": .publicSafe(index)]
    }

    /// Same construction-holds-the-guarantee shape as `dropLogFields`, for
    /// the aggregate line: only a count crosses this boundary.
    static func dropCountLogFields(_ count: Int) -> [String: LogSensitivity] {
        ["quoteValidationDropCount": .publicSafe(count)]
    }

    /// Builds the Messages API request body directly via `JSONSerialization`
    /// (matching `AnthropicResponse.parse`'s own style) rather than a
    /// `Codable` request type, since the block list's shape (which blocks
    /// exist, which one carries `cache_control`) depends on which prompt
    /// blocks are non-empty — state that's simpler to assemble as a mutable
    /// array than to model as a fixed set of `Codable` fields.
    private static func buildRequestBody(prompt: SummarizationPrompt, modelIdentifier: String) throws -> Data {
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
        // last non-empty cacheable block before the transcript carries
        // `cache_control` — marking every cacheable block individually would
        // be redundant (Decision 3.5's caching table).
        if let lastCacheableBlockIndex {
            contentBlocks[lastCacheableBlockIndex]["cache_control"] = cacheControl
        }
        // The transcript is unique per meeting and never cached.
        contentBlocks.append(["type": "text", "text": prompt.transcript.text])

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
    /// `AnthropicHTTPClient` never inspects. This strategy owns decoding it:
    /// concatenate every `"type": "text"` block's `text`, then decode that
    /// string as the JSON answer the substring prompt asked for. Any failure
    /// along the way — no text block, invalid JSON, missing/mistyped fields
    /// — is a malformed response from this strategy's point of view, not a
    /// transport-layer concern.
    private static func decodeModelAnswer(from content: Data) throws -> ClaudeSubstringModelAnswer {
        guard let blocks = (try? JSONSerialization.jsonObject(with: content)) as? [[String: Any]] else {
            throw SummarizerError.malformedResponse
        }

        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else {
            throw SummarizerError.malformedResponse
        }

        guard let answer = try? JSONDecoder().decode(ClaudeSubstringModelAnswer.self, from: Data(text.utf8)) else {
            throw SummarizerError.malformedResponse
        }
        return answer
    }
}
