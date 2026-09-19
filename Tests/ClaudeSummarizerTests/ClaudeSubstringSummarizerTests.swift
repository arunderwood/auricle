@testable import ClaudeSummarizer
import Core
import Foundation
@testable import Summarize
import SummarizerInterface
import Testing

// MARK: - URLProtocol stub

/// A single canned response per test, keyed by a per-test unique endpoint
/// URL rather than a shared queue or header token — `ClaudeSubstringSummarizer`
/// builds its own `AnthropicRequest` with no caller-visible header hook, so
/// the endpoint itself (already an `AnthropicHTTPClient` constructor
/// parameter, used the same way in production to reach the real API) is the
/// natural per-test key. No retry/backoff/attempt-tracking machinery here —
/// that's already covered by Story 3.3's own `AnthropicHTTPClientTests`.
private final class SubstringStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responses: [URL: (status: Int, body: Data)] = [:]
    private nonisolated(unsafe) static var capturedRequests: [URL: URLRequest] = [:]

    static func register(url: URL, status: Int, body: Data) {
        lock.lock()
        responses[url] = (status, body)
        lock.unlock()
    }

    static func unregister(url: URL) {
        lock.lock()
        responses.removeValue(forKey: url)
        capturedRequests.removeValue(forKey: url)
        lock.unlock()
    }

    static func capturedRequest(for url: URL) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests[url]
    }

    /// A registered `URLProtocol` always sees a POST body as
    /// `httpBodyStream`, never `httpBody`, regardless of how the caller set
    /// it — draining the stream is the only way to recover the bytes a test
    /// needs to inspect.
    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        Self.lock.lock()
        Self.capturedRequests[url] = request
        let response = Self.responses[url]
        Self.lock.unlock()

        guard
            let response,
            let httpResponse = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Test support

private func uniqueEndpoint() -> URL {
    URL(string: "https://stub.invalid/\(UUID().uuidString)")!
}

private func makeSummarizer(endpoint: URL, promptDir: URL? = nil) -> ClaudeSubstringSummarizer {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SubstringStubURLProtocol.self]
    let httpClient = AnthropicHTTPClient(
        session: URLSession(configuration: configuration),
        endpoint: endpoint,
        apiKeyProvider: { "test-key" },
        sleep: { _ in },
    )
    return ClaudeSubstringSummarizer(httpClient: httpClient, promptDir: promptDir)
}

private func makeTranscript() -> CanonicalTranscript {
    CanonicalTranscript(
        text: "Ben: I'll take a first pass at the brief by Friday.\nPriya: Let's push the launch to the 15th.",
        utterances: [
            CanonicalTranscript.Utterance(speakerLabel: "Ben", start: 0, end: 51),
            CanonicalTranscript.Utterance(speakerLabel: "Priya", start: 52, end: 93),
        ],
    )
}

private func makeGlossary() -> Glossary {
    Glossary(people: ["Ben", "Priya Patel"], projects: ["chicken-palace"])
}

/// The raw JSON text `ClaudeSubstringSummarizer` expects inside the
/// response's one `"type": "text"` content block — the model's answer to
/// the substring prompt, before any grounding validation runs.
private func modelAnswerJSON(
    summary: String = "Team discussed launch plans.",
    actionItems: [(text: String, quote: String)] = [],
    decisions: [(text: String, quote: String)] = [],
) throws -> String {
    let payload: [String: Any] = [
        "summary": summary,
        "action_items": actionItems.map { ["text": $0.text, "source_transcript_quote": $0.quote] },
        "decisions": decisions.map { ["text": $0.text, "source_transcript_quote": $0.quote] },
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try #require(String(bytes: data, encoding: .utf8))
}

/// Wraps a model-answer JSON string in the Messages API's standard envelope
/// `AnthropicHTTPClient.send(_:)` already knows how to parse.
private func makeEnvelope(modelAnswerText: String, model: String = "claude-opus-5", stopReason: String = "end_turn") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "model": model,
        "content": [["type": "text", "text": modelAnswerText]],
        "stop_reason": stopReason,
        "usage": ["input_tokens": 100, "output_tokens": 50],
    ])
}

// MARK: - All quotes valid

@Test func allQuotesValidReturnsEveryItemGroundedWithSubstringSourceMethod() async throws {
    let transcript = makeTranscript()
    let actionQuote = "I'll take a first pass at the brief by Friday."
    let decisionQuote = "Let's push the launch to the 15th."
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON(
        actionItems: [(text: "Ben drafts the brief", quote: actionQuote)],
        decisions: [(text: "Launch moves to the 15th", quote: decisionQuote)],
    )
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: answer))

    let result = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(),
    )

    let expectedActionPointer = try #require(SubstringGroundingValidator.validate(quote: actionQuote, in: transcript))
    let expectedDecisionPointer = try #require(SubstringGroundingValidator.validate(quote: decisionQuote, in: transcript))
    #expect(result.actionItems == [GroundedItem(text: "Ben drafts the brief", grounding: expectedActionPointer)])
    #expect(result.decisions == [GroundedItem(text: "Launch moves to the 15th", grounding: expectedDecisionPointer)])
    #expect(result.actionItems[0].grounding.sourceMethod == .substring)
    #expect(result.groundingMethod == .substring)
    #expect(result.quoteValidationDropCount == 0)
    #expect(result.schemaVersion == 1)
    #expect(result.cost == SummarizerCost(inputTokens: 100, outputTokens: 50, thinkingTokens: 0, costUSD: result.cost.costUSD))
    #expect(result.cost.costUSD > 0)
}

// MARK: - Mixed valid/invalid quotes

@Test func mixedValidAndInvalidQuotesDropsOnlyTheInvalidItems() async throws {
    let transcript = makeTranscript()
    let validQuote = "I'll take a first pass at the brief by Friday."
    let invalidQuote = "This sentence never appears anywhere in the transcript."
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON(
        actionItems: [
            (text: "Ben drafts the brief", quote: validQuote),
            (text: "A commitment nobody made", quote: invalidQuote),
        ],
        decisions: [(text: "A decision nobody made", quote: invalidQuote)],
    )
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: answer))

    let result = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(),
    )

    #expect(result.actionItems.count == 1)
    #expect(result.actionItems[0].text == "Ben drafts the brief")
    #expect(result.decisions.isEmpty)
    #expect(result.quoteValidationDropCount == 2)
}

@Test func oneDroppedItemOfThreeReportsAQuoteValidationDropCountOfOne() async throws {
    let transcript = makeTranscript()
    let actionQuote = "I'll take a first pass at the brief by Friday."
    let decisionQuote = "Let's push the launch to the 15th."
    let invalidQuote = "This sentence never appears anywhere in the transcript."
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON(
        actionItems: [
            (text: "Ben drafts the brief", quote: actionQuote),
            (text: "A commitment nobody made", quote: invalidQuote),
        ],
        decisions: [(text: "Launch moves to the 15th", quote: decisionQuote)],
    )
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: answer))

    let result = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(),
    )

    #expect(result.actionItems.count == 1)
    #expect(result.decisions.count == 1)
    #expect(result.quoteValidationDropCount == 1)
}

// MARK: - Items without a quote

/// One item carrying no usable quote must not cost the whole paid call: it is
/// dropped and counted, and the item next to it is still grounded.
@Test(arguments: [
    #"{"text": "Ben drafts the brief"}"#,
    #"{"text": "Ben drafts the brief", "source_transcript_quote": ""}"#,
    #"{"text": "Ben drafts the brief", "source_transcript_quote": null}"#,
])
func anItemWithAMissingOrEmptyQuoteIsDroppedAndTheCallStillSucceeds(ungroundedItem: String) async throws {
    let transcript = makeTranscript()
    let decisionQuote = "Let's push the launch to the 15th."
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    let answer = """
    {"summary": "Team discussed launch plans.", "action_items": [\(ungroundedItem)], \
    "decisions": [{"text": "Launch moves to the 15th", "source_transcript_quote": "\(decisionQuote)"}]}
    """
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: answer))

    let result = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(),
    )

    #expect(result.actionItems.isEmpty)
    #expect(result.decisions.map(\.text) == ["Launch moves to the 15th"])
    #expect(result.quoteValidationDropCount == 1)
    #expect(result.cost.costUSD > 0)
}

@Test func anItemWhoseQuoteIsOfTheWrongTypeStillThrowsMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    let payload: [String: Any] = [
        "summary": "Team discussed launch plans.",
        "action_items": [["text": "Ben drafts the brief", "source_transcript_quote": 7]],
        "decisions": [],
    ]
    let answer = try #require(String(bytes: JSONSerialization.data(withJSONObject: payload), encoding: .utf8))
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: answer))

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

// MARK: - Truncated response

/// A `max_tokens` stop leaves the JSON cut off mid-value. That is a budget
/// problem, not a malformed answer, and the two must not share a class.
@Test func aResponseCutOffAtMaxTokensThrowsResponseTruncatedNotMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    let cutOff = #"{"summary": "Team discussed launch plans.", "action_items": [{"text": "Ben dra"#
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: cutOff, stopReason: "max_tokens"))

    await #expect(throws: SummarizerError.responseTruncated) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

@Test func aCutOffBodyWithAnOrdinaryStopReasonIsStillMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    let cutOff = #"{"summary": "Team discussed launch plans.", "action_items": [{"text": "Ben dra"#
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: cutOff))

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

// MARK: - Structurally malformed JSON

@Test func textBlockThatIsNotValidJSONThrowsMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: "not valid json at all"))

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

@Test func textBlockMissingRequiredFieldsThrowsMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    let incompleteData = try JSONSerialization.data(withJSONObject: ["summary": "Missing the item arrays"])
    let incompleteAnswer = try #require(String(bytes: incompleteData, encoding: .utf8))
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: incompleteAnswer))

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

@Test func responseWithNoTextContentBlockThrowsMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "claude-opus-5",
        "content": [["type": "tool_use", "name": "not_text"]],
        "stop_reason": "end_turn",
        "usage": ["input_tokens": 100, "output_tokens": 50],
    ])
    SubstringStubURLProtocol.register(url: endpoint, status: 200, body: body)

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

// MARK: - Empty arrays

@Test func emptyActionItemsAndDecisionsReturnEmptyArraysWithNoError() async throws {
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: modelAnswerJSON()))

    let result = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
    )

    #expect(result.actionItems == [])
    #expect(result.decisions == [])
}

// MARK: - Request shape

/// The one test the spec calls for that asserts the sent request's blocks
/// against `SummarizationPromptBuilder.build(...)`'s own real output for the
/// same fixture, rather than a hand-duplicated string — and that exactly one
/// block carries `cache_control` ahead of the (always uncached) transcript.
@Test func requestBodyMatchesTheSharedPromptBuilderOutputAndCitationsIsNeverSent() async throws {
    let transcript = makeTranscript()
    let glossary = makeGlossary()
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: modelAnswerJSON()))

    _ = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: glossary, config: SummarizerConfig(modelIdentifier: "claude-opus-5"),
    )

    let sentRequest = try #require(SubstringStubURLProtocol.capturedRequest(for: endpoint))
    let bodyData = try #require(SubstringStubURLProtocol.bodyData(from: sentRequest))
    let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

    // A default `SummarizerConfig` carries no attendee names, so the shared
    // builder's `attendeeContext` block is empty in this call shape — the same
    // real call this strategy itself makes, not a re-derived string.
    let expectedPrompt = try SummarizationPromptBuilder.build(
        transcript: transcript, glossary: glossary, attendees: [], mode: .substring, promptDir: nil,
    )
    #expect(expectedPrompt.attendeeContext.text.isEmpty)

    #expect(json["model"] as? String == "claude-opus-5")
    #expect(json["citations"] == nil)

    let systemBlocks = try #require(json["system"] as? [[String: Any]])
    #expect(systemBlocks.count == 1)
    #expect(systemBlocks[0]["text"] as? String == expectedPrompt.system.text)
    #expect((systemBlocks[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])

    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")

    let contentBlocks = try #require(messages[0]["content"] as? [[String: Any]])
    // glossary (cache_control — the last non-empty block before the
    // transcript, since attendeeContext is empty here), transcript
    // (never cache_control).
    #expect(contentBlocks.count == 2)
    #expect(contentBlocks[0]["text"] as? String == expectedPrompt.glossary.text)
    #expect((contentBlocks[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
    #expect(contentBlocks[1]["text"] as? String == expectedPrompt.transcript.text)
    #expect(contentBlocks[1]["cache_control"] == nil)
}

/// The configuration four of this file's five behavioral tests actually
/// send (`Glossary()`, no attendee names): with both optional blocks empty,
/// `content` must reduce to the transcript alone, uncached.
@Test func requestBodyHasOnlyTheTranscriptBlockWhenGlossaryAndAttendeeContextAreEmpty() async throws {
    let transcript = makeTranscript()
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: modelAnswerJSON()))

    _ = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(),
    )

    let expectedPrompt = try SummarizationPromptBuilder.build(
        transcript: transcript, glossary: Glossary(), attendees: [], mode: .substring, promptDir: nil,
    )
    #expect(expectedPrompt.glossary.text.isEmpty)
    #expect(expectedPrompt.attendeeContext.text.isEmpty)

    let sentRequest = try #require(SubstringStubURLProtocol.capturedRequest(for: endpoint))
    let bodyData = try #require(SubstringStubURLProtocol.bodyData(from: sentRequest))
    let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let contentBlocks = try #require(messages[0]["content"] as? [[String: Any]])

    #expect(contentBlocks.count == 1)
    #expect(contentBlocks[0]["text"] as? String == expectedPrompt.transcript.text)
    #expect(contentBlocks[0]["cache_control"] == nil)
}

/// A prompt comparison builds two substring arms that differ only in their
/// prompt directory, so the directory must reach the request the API sees.
@Test func promptDirOverrideReachesTheSentSystemPrompt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let overriddenSystem = "OVERRIDDEN SYSTEM PROMPT"
    try AtomicWriter.write(Data(overriddenSystem.utf8), to: directory.appendingPathComponent("system.md"))

    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: modelAnswerJSON()))

    _ = try await makeSummarizer(endpoint: endpoint, promptDir: directory).summarize(
        transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
    )

    let sentRequest = try #require(SubstringStubURLProtocol.capturedRequest(for: endpoint))
    let bodyData = try #require(SubstringStubURLProtocol.bodyData(from: sentRequest))
    let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let systemBlocks = try #require(json["system"] as? [[String: Any]])
    let systemText = try #require(systemBlocks[0]["text"] as? String)
    #expect(systemText.hasPrefix(overriddenSystem))
}

// MARK: - Log field construction

/// Mirrors `redactedLogFieldsNeverContainTheResponseBodyMarker` (Story 3.3):
/// `dropLogFields` takes only a section and an index, so a passing test here
/// proves no third field — in particular, no quote/item-text field — has
/// been added to the drop log line.
@Test func dropLogFieldsContainsOnlySectionAndIndex() {
    let fields = ClaudeSubstringSummarizer.dropLogFields(section: "actionItem", index: 3)
    #expect(fields.count == 2)
    #expect(Set(fields.keys) == ["section", "index"])
}

@Test func dropCountLogFieldsContainsOnlyTheAggregateCount() {
    let fields = ClaudeSubstringSummarizer.dropCountLogFields(5)
    #expect(fields.count == 1)
    #expect(Set(fields.keys) == ["quoteValidationDropCount"])
}

/// The attendee names on the config are the only attendee data the request
/// carries: the same builder output as `attendees: config.attendeeNames`, as
/// its own cacheable block, and nothing else about anyone.
@Test func substringRequestCarriesTheConfigAttendeeNamesAsTheAttendeeContextBlock() async throws {
    let transcript = makeTranscript()
    let endpoint = uniqueEndpoint()
    defer { SubstringStubURLProtocol.unregister(url: endpoint) }
    try SubstringStubURLProtocol.register(url: endpoint, status: 200, body: makeEnvelope(modelAnswerText: modelAnswerJSON()))
    let names = ["Ada Lovelace", "Ben Ng"]

    _ = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(attendeeNames: names),
    )

    let sentRequest = try #require(SubstringStubURLProtocol.capturedRequest(for: endpoint))
    let bodyData = try #require(SubstringStubURLProtocol.bodyData(from: sentRequest))
    let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let contentBlocks = try #require(messages[0]["content"] as? [[String: Any]])

    let expectedPrompt = try SummarizationPromptBuilder.build(
        transcript: transcript, glossary: Glossary(), attendees: names, mode: .substring, promptDir: nil,
    )
    #expect(expectedPrompt.attendeeContext.text == "Attendees: Ada Lovelace, Ben Ng")
    #expect(contentBlocks.count == 2)
    #expect(contentBlocks[0]["text"] as? String == expectedPrompt.attendeeContext.text)
    #expect((contentBlocks[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
    #expect(contentBlocks[1]["text"] as? String == transcript.text)
}
