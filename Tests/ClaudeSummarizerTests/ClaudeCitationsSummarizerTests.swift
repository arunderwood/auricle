@testable import ClaudeSummarizer
import Core
import Foundation
@testable import Summarize
import SummarizerInterface
import Testing

// MARK: - URLProtocol stub

/// A single canned response per test, keyed by a per-test unique endpoint
/// URL — the same file-local convention `ClaudeSubstringSummarizerTests`
/// established, not shared with it or with `AnthropicHTTPClientTests`'s own
/// stub, per the spec's own file-local-stub requirement.
private final class CitationsStubURLProtocol: URLProtocol, @unchecked Sendable {
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
    URL(string: "https://citations-stub.invalid/\(UUID().uuidString)")!
}

private func makeSummarizer(endpoint: URL) -> ClaudeCitationsSummarizer {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CitationsStubURLProtocol.self]
    let httpClient = AnthropicHTTPClient(
        session: URLSession(configuration: configuration),
        endpoint: endpoint,
        apiKeyProvider: { "test-key" },
        sleep: { _ in },
    )
    return ClaudeCitationsSummarizer(httpClient: httpClient)
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

private func modelAnswerJSON(
    summary: String = "Team discussed launch plans.",
    actionItems: [(text: String, sourceBlockIndex: Int)] = [],
    decisions: [(text: String, sourceBlockIndex: Int)] = [],
) throws -> String {
    let payload: [String: Any] = [
        "summary": summary,
        "action_items": actionItems.map { ["text": $0.text, "source_block_index": $0.sourceBlockIndex] },
        "decisions": decisions.map { ["text": $0.text, "source_block_index": $0.sourceBlockIndex] },
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try #require(String(bytes: data, encoding: .utf8))
}

/// Builds a Messages API response envelope whose `content` reproduces the
/// positional shape Anthropic's Citations API actually returns (see
/// `citation_item_association_result.json`): one block carrying the full
/// JSON answer text (no citations), followed by one citation-bearing block
/// per real citation, in item order. `ClaudeCitationsSummarizer` only reads
/// block order and each citation-bearing block's first citation object, so
/// where exactly the JSON text itself is split doesn't matter here — only
/// that concatenating every "text" block's `text` reproduces the answer.
private func makeCitationsEnvelope(answerJSON: String, citations: [[String: Any]], model: String = "claude-opus-5") throws -> Data {
    var blocks: [[String: Any]] = [["type": "text", "text": answerJSON]]
    for citation in citations {
        blocks.append(["type": "text", "text": "", "citations": [citation]])
    }
    return try JSONSerialization.data(withJSONObject: [
        "model": model,
        "content": blocks,
        "stop_reason": "end_turn",
        "usage": ["input_tokens": 100, "output_tokens": 50],
    ])
}

// MARK: - All items cited

@Test func allItemsCitedReturnsEveryItemGroundedWithCitationsSourceMethod() async throws {
    let transcript = makeTranscript()
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON(
        actionItems: [(text: "Ben drafts the brief", sourceBlockIndex: 0)],
        decisions: [(text: "Launch moves to the 15th", sourceBlockIndex: 1)],
    )
    let body = try makeCitationsEnvelope(
        answerJSON: answer,
        citations: [
            ["start_block_index": 0, "end_block_index": 1],
            ["start_block_index": 1, "end_block_index": 2],
        ],
    )
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    let result = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(),
    )

    #expect(result.actionItems == [
        GroundedItem(text: "Ben drafts the brief", grounding: GroundingPointer(transcriptStart: 0, transcriptEnd: 51, sourceMethod: .citations)),
    ])
    #expect(result.decisions == [
        GroundedItem(text: "Launch moves to the 15th", grounding: GroundingPointer(transcriptStart: 52, transcriptEnd: 93, sourceMethod: .citations)),
    ])
    #expect(result.groundingMethod == .citations)
    #expect(result.quoteValidationDropCount == 0)
    #expect(result.schemaVersion == 1)
    #expect(result.cost == SummarizerCost(inputTokens: 100, outputTokens: 50, thinkingTokens: 0, costUSD: result.cost.costUSD))
    #expect(result.cost.costUSD > 0)
}

// MARK: - No citations at all

@Test func zeroCitationBearingBlocksThrowsCitationsUnavailable() async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON(actionItems: [(text: "Ben drafts the brief", sourceBlockIndex: 0)])
    let body = try makeCitationsEnvelope(answerJSON: answer, citations: [])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    await #expect(throws: SummarizerError.citationsUnavailable) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

// MARK: - Partial/mismatched citation count

@Test func citationCountMismatchThrowsMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON(
        actionItems: [(text: "Ben drafts the brief", sourceBlockIndex: 0)],
        decisions: [(text: "Launch moves to the 15th", sourceBlockIndex: 1)],
    )
    // Two items, only one citation-bearing block.
    let body = try makeCitationsEnvelope(answerJSON: answer, citations: [["start_block_index": 0, "end_block_index": 1]])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

// MARK: - Out-of-range block index

@Test func outOfRangeBlockIndexThrowsMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON(actionItems: [(text: "Ben drafts the brief", sourceBlockIndex: 0)])
    // The fixture transcript has 2 utterances; end_block_index 5 is out of range.
    let body = try makeCitationsEnvelope(answerJSON: answer, citations: [["start_block_index": 0, "end_block_index": 5]])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

@Test func citationCountMismatchOverSupplyThrowsMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON(actionItems: [(text: "Ben drafts the brief", sourceBlockIndex: 0)])
    // One item, two citation-bearing blocks.
    let body = try makeCitationsEnvelope(
        answerJSON: answer,
        citations: [
            ["start_block_index": 0, "end_block_index": 1],
            ["start_block_index": 1, "end_block_index": 2],
        ],
    )
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

// MARK: - Structurally malformed JSON

@Test func modelAnswerThatIsNotValidJSONThrowsMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let body = try makeCitationsEnvelope(answerJSON: "not valid json at all", citations: [])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

@Test func modelAnswerMissingRequiredFieldsThrowsMalformedResponse() async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let incompleteData = try JSONSerialization.data(withJSONObject: ["summary": "Missing the item arrays"])
    let incompleteAnswer = try #require(String(bytes: incompleteData, encoding: .utf8))
    let body = try makeCitationsEnvelope(answerJSON: incompleteAnswer, citations: [])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await makeSummarizer(endpoint: endpoint).summarize(
            transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
        )
    }
}

// MARK: - Empty arrays

@Test func citationsEmptyActionItemsAndDecisionsReturnEmptyArraysWithNoError() async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON()
    let body = try makeCitationsEnvelope(answerJSON: answer, citations: [])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    let result = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
    )

    #expect(result.actionItems == [])
    #expect(result.decisions == [])
    #expect(result.groundingMethod == .citations)
    #expect(result.quoteValidationDropCount == 0)
}

// MARK: - Multiple citations on one block

/// `citationBearingBlockCitations`'s `.first`-per-block selection: a block
/// carrying two citation objects must ground from the first one specifically,
/// not merely "some" entry — using the second citation's block range here
/// would resolve to the other utterance entirely.
@Test func blockWithMultipleCitationsGroundsFromTheFirstCitationOnly() async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let answer = try modelAnswerJSON(actionItems: [(text: "Ben drafts the brief", sourceBlockIndex: 0)])
    let blocks: [[String: Any]] = [
        ["type": "text", "text": answer],
        [
            "type": "text",
            "text": "",
            "citations": [
                ["start_block_index": 0, "end_block_index": 1],
                ["start_block_index": 1, "end_block_index": 2],
            ],
        ],
    ]
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "claude-opus-5",
        "content": blocks,
        "stop_reason": "end_turn",
        "usage": ["input_tokens": 100, "output_tokens": 50],
    ])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    let result = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
    )

    #expect(result.actionItems == [
        GroundedItem(text: "Ben drafts the brief", grounding: GroundingPointer(transcriptStart: 0, transcriptEnd: 51, sourceMethod: .citations)),
    ])
}

// MARK: - Citation-bearing blocks carrying real answer text

/// Adapted from `citation_item_association_result.json`'s `arm_b` evidence:
/// the real Anthropic API splits the JSON answer text across many blocks,
/// and the blocks carrying citations are not empty placeholders — they carry
/// a genuine chunk of the answer text. `decodeModelAnswer`'s concatenation
/// doesn't filter by the presence of a `citations` key, but nothing prior to
/// this test exercised that: every other fixture's citation-bearing blocks
/// carry `"text": ""`.
@Test func citationBearingBlocksCarryingNonEmptyTextStillDecodeAndGround() async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let answerJSON = try modelAnswerJSON(
        actionItems: [(text: "Ben drafts the brief", sourceBlockIndex: 0)],
        decisions: [(text: "Launch moves to the 15th", sourceBlockIndex: 1)],
    )
    let characters = Array(answerJSON)
    let firstSplit = characters.count / 3
    let secondSplit = 2 * characters.count / 3
    let part1 = String(characters[0 ..< firstSplit])
    let part2 = String(characters[firstSplit ..< secondSplit])
    let part3 = String(characters[secondSplit...])

    let blocks: [[String: Any]] = [
        ["type": "text", "text": part1],
        ["type": "text", "text": part2, "citations": [["start_block_index": 0, "end_block_index": 1]]],
        ["type": "text", "text": part3, "citations": [["start_block_index": 1, "end_block_index": 2]]],
    ]
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "claude-opus-5",
        "content": blocks,
        "stop_reason": "end_turn",
        "usage": ["input_tokens": 100, "output_tokens": 50],
    ])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    let result = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(),
    )

    #expect(result.summary == "Team discussed launch plans.")
    #expect(result.actionItems == [
        GroundedItem(text: "Ben drafts the brief", grounding: GroundingPointer(transcriptStart: 0, transcriptEnd: 51, sourceMethod: .citations)),
    ])
    #expect(result.decisions == [
        GroundedItem(text: "Launch moves to the 15th", grounding: GroundingPointer(transcriptStart: 52, transcriptEnd: 93, sourceMethod: .citations)),
    ])
}

// MARK: - Request shape

/// The one test the spec calls for that asserts the sent request's document
/// content block matches `transcript.utterances` 1:1, plus that no
/// `output_config.format` field is ever sent (Anthropic returns 400 when
/// that's combined with `citations.enabled: true`) and that `cache_control`
/// lands on exactly the intended block.
@Test func requestBodySendsOneDocumentContentBlockPerUtteranceWithCitationsEnabledAndNoOutputFormat() async throws {
    let transcript = makeTranscript()
    let glossary = makeGlossary()
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let body = try makeCitationsEnvelope(answerJSON: modelAnswerJSON(), citations: [])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    _ = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: glossary, config: SummarizerConfig(modelIdentifier: "claude-opus-5"),
    )

    let sentRequest = try #require(CitationsStubURLProtocol.capturedRequest(for: endpoint))
    let bodyData = try #require(CitationsStubURLProtocol.bodyData(from: sentRequest))
    let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

    #expect(json["model"] as? String == "claude-opus-5")
    let outputConfig = try #require(json["output_config"] as? [String: Any])
    #expect(outputConfig["format"] == nil)
    #expect(json["citations"] == nil)

    let expectedPrompt = try SummarizationPromptBuilder.build(
        transcript: transcript, glossary: glossary, attendees: [], mode: .citations, promptDir: nil,
    )
    let systemBlocks = try #require(json["system"] as? [[String: Any]])
    #expect(systemBlocks.count == 1)
    #expect(systemBlocks[0]["text"] as? String == expectedPrompt.system.text)
    #expect((systemBlocks[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])

    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")

    let contentBlocks = try #require(messages[0]["content"] as? [[String: Any]])
    // glossary (cache_control — the last non-empty block before the
    // document, since a default config carries no attendee names),
    // document (never cache_control).
    #expect(contentBlocks.count == 2)
    #expect(contentBlocks[0]["text"] as? String == expectedPrompt.glossary.text)
    #expect((contentBlocks[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])

    let documentBlock = contentBlocks[1]
    #expect(documentBlock["type"] as? String == "document")
    #expect((documentBlock["citations"] as? [String: Bool]) == ["enabled": true])
    #expect(documentBlock["cache_control"] == nil)

    let source = try #require(documentBlock["source"] as? [String: Any])
    #expect(source["type"] as? String == "content")
    let documentContentBlocks = try #require(source["content"] as? [[String: Any]])
    #expect(documentContentBlocks.count == transcript.utterances.count)
    let transcriptBytes = Array(transcript.text.utf8)
    for (block, utterance) in zip(documentContentBlocks, transcript.utterances) {
        let expectedText = try #require(String(bytes: transcriptBytes[utterance.start ..< utterance.end], encoding: .utf8))
        #expect(block["type"] as? String == "text")
        #expect(block["text"] as? String == expectedText)
    }
}

/// The configuration most of this suite doesn't hit: `glossary` empty and
/// (a default config carries no attendee names) `attendeeContext` also empty,
/// so the document block is the *only* content
/// block sent, with no `cache_control` anywhere.
@Test func emptyGlossarySendsOnlyTheDocumentContentBlockWithNoCacheControl() async throws {
    let transcript = makeTranscript()
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let body = try makeCitationsEnvelope(answerJSON: modelAnswerJSON(), citations: [])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    _ = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(),
    )

    let sentRequest = try #require(CitationsStubURLProtocol.capturedRequest(for: endpoint))
    let bodyData = try #require(CitationsStubURLProtocol.bodyData(from: sentRequest))
    let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let contentBlocks = try #require(messages[0]["content"] as? [[String: Any]])

    #expect(contentBlocks.count == 1)
    #expect(contentBlocks[0]["type"] as? String == "document")
    #expect(contentBlocks[0]["cache_control"] == nil)
}

/// The attendee names on the config are the only attendee data the request
/// carries: the same builder output as `attendees: config.attendeeNames`, as
/// its own cacheable block ahead of the uncached document.
/// Explicit wire names, not `rawValue`: the strings are the API's contract.
@Test(arguments: [
    (EffortLevel.low, "low"),
    (EffortLevel.medium, "medium"),
    (EffortLevel.high, "high"),
    (EffortLevel.xhigh, "xhigh"),
    (EffortLevel.max, "max"),
])
func citationsRequestSendsTheConfiguredEffortAsOutputConfigEffort(level: EffortLevel, wireName: String) async throws {
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let body = try makeCitationsEnvelope(answerJSON: modelAnswerJSON(), citations: [])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)

    _ = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: makeTranscript(), glossary: Glossary(), config: SummarizerConfig(effortLevel: level),
    )

    let sentRequest = try #require(CitationsStubURLProtocol.capturedRequest(for: endpoint))
    let bodyData = try #require(CitationsStubURLProtocol.bodyData(from: sentRequest))
    let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(json["output_config"] as? [String: String] == ["effort": wireName])
}

@Test func citationsRequestCarriesTheConfigAttendeeNamesAsTheAttendeeContextBlock() async throws {
    let transcript = makeTranscript()
    let endpoint = uniqueEndpoint()
    defer { CitationsStubURLProtocol.unregister(url: endpoint) }
    let body = try makeCitationsEnvelope(answerJSON: modelAnswerJSON(), citations: [])
    CitationsStubURLProtocol.register(url: endpoint, status: 200, body: body)
    let names = ["Ada Lovelace", "Ben Ng"]

    _ = try await makeSummarizer(endpoint: endpoint).summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(attendeeNames: names),
    )

    let sentRequest = try #require(CitationsStubURLProtocol.capturedRequest(for: endpoint))
    let bodyData = try #require(CitationsStubURLProtocol.bodyData(from: sentRequest))
    let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let contentBlocks = try #require(messages[0]["content"] as? [[String: Any]])

    let expectedPrompt = try SummarizationPromptBuilder.build(
        transcript: transcript, glossary: Glossary(), attendees: names, mode: .citations, promptDir: nil,
    )
    #expect(expectedPrompt.attendeeContext.text == "Attendees: Ada Lovelace, Ben Ng")
    #expect(contentBlocks.count == 2)
    #expect(contentBlocks[0]["text"] as? String == expectedPrompt.attendeeContext.text)
    #expect((contentBlocks[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
    #expect(contentBlocks[1]["type"] as? String == "document")
    #expect(contentBlocks[1]["cache_control"] == nil)
}
