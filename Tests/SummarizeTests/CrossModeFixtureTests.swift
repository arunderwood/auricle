import ClaudeSummarizer
import Core
import Foundation
import SummarizerInterface
import Testing

// Decision 3.4's cross-mode fixture test: one golden transcript run through
// both grounding strategies, with stubbed responses producing equivalent
// content via each mode's own shape, asserting byte-identical renderer
// output. This proves the strategies can genuinely swap for each other, not
// just that each satisfies its own protocol contract in isolation.

// MARK: - URLProtocol stub

/// A single canned response per test, keyed by a per-test unique endpoint
/// URL — file-local to this file, not shared with any other test target's
/// own stub.
private final class CrossModeStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responses: [URL: (status: Int, body: Data)] = [:]

    static func register(url: URL, status: Int, body: Data) {
        lock.lock()
        responses[url] = (status, body)
        lock.unlock()
    }

    static func unregister(url: URL) {
        lock.lock()
        responses.removeValue(forKey: url)
        lock.unlock()
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

// MARK: - Fixture

private func makeTranscript() -> CanonicalTranscript {
    CanonicalTranscript(
        text: "Ben: I'll take a first pass at the brief by Friday.\nPriya: Let's push the launch to the 15th.",
        utterances: [
            CanonicalTranscript.Utterance(speakerLabel: "Ben", start: 0, end: 51),
            CanonicalTranscript.Utterance(speakerLabel: "Priya", start: 52, end: 93),
        ],
    )
}

private func uniqueEndpoint() -> URL {
    URL(string: "https://cross-mode-stub.invalid/\(UUID().uuidString)")!
}

private func makeHTTPClient(endpoint: URL) -> AnthropicHTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CrossModeStubURLProtocol.self]
    return AnthropicHTTPClient(
        session: URLSession(configuration: configuration),
        endpoint: endpoint,
        apiKeyProvider: { "test-key" },
        sleep: { _ in },
    )
}

private func makeEnvelope(contentBlocks: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "model": "claude-opus-5",
        "content": contentBlocks,
        "stop_reason": "end_turn",
        "usage": ["input_tokens": 100, "output_tokens": 50],
    ])
}

/// Renders one item the way the persist-stage renderer eventually will
/// (Story 3.7+): the item text, then the exact cited transcript span as an
/// Obsidian blockquote. Grounding-method-agnostic by construction — it only
/// reads `GroundedItem.text` and `transcript.text[start..<end]`, never
/// `grounding.sourceMethod`.
private func render(_ item: GroundedItem, transcript: CanonicalTranscript) throws -> String {
    let bytes = Array(transcript.text.utf8)
    let quoted = try #require(String(bytes: bytes[item.grounding.transcriptStart ..< item.grounding.transcriptEnd], encoding: .utf8))
    return "\(item.text)\n> \(quoted)"
}

// MARK: - Cross-mode fixture

@Test func citationsAndSubstringStrategiesRenderByteIdenticalOutputForEquivalentContent() async throws {
    let transcript = makeTranscript()
    let bytes = Array(transcript.text.utf8)
    let actionUtterance = transcript.utterances[0]
    let decisionUtterance = transcript.utterances[1]
    // The substring strategy's "verbatim quote" is the utterance's own full
    // text — the same span the citations strategy grounds to via a whole-
    // block citation — so both strategies must resolve to identical offsets
    // for this fixture, making a byte-identical rendered-output comparison
    // meaningful.
    let actionQuote = try #require(String(bytes: bytes[actionUtterance.start ..< actionUtterance.end], encoding: .utf8))
    let decisionQuote = try #require(String(bytes: bytes[decisionUtterance.start ..< decisionUtterance.end], encoding: .utf8))

    // Substring-mode stub.
    let substringEndpoint = uniqueEndpoint()
    defer { CrossModeStubURLProtocol.unregister(url: substringEndpoint) }
    let substringAnswerData = try JSONSerialization.data(withJSONObject: [
        "summary": "Team assigned the brief and moved the launch date.",
        "action_items": [["text": "Ben drafts the brief", "source_transcript_quote": actionQuote]],
        "decisions": [["text": "Launch moves to the 15th", "source_transcript_quote": decisionQuote]],
    ])
    let substringAnswer = try #require(String(bytes: substringAnswerData, encoding: .utf8))
    try CrossModeStubURLProtocol.register(
        url: substringEndpoint, status: 200,
        body: makeEnvelope(contentBlocks: [["type": "text", "text": substringAnswer]]),
    )
    let substringSummarizer = ClaudeSubstringSummarizer(httpClient: makeHTTPClient(endpoint: substringEndpoint))
    let substringResult = try await substringSummarizer.summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(),
    )

    // Citations-mode stub: the same items, via Citations' own shape — one
    // block carrying the full JSON answer, plus one citation-bearing block
    // per item (in item order), matching the positional association
    // architecture.md documents.
    let citationsEndpoint = uniqueEndpoint()
    defer { CrossModeStubURLProtocol.unregister(url: citationsEndpoint) }
    let citationsAnswerData = try JSONSerialization.data(withJSONObject: [
        "summary": "Team assigned the brief and moved the launch date.",
        "action_items": [["text": "Ben drafts the brief", "source_block_index": 0]],
        "decisions": [["text": "Launch moves to the 15th", "source_block_index": 1]],
    ])
    let citationsAnswer = try #require(String(bytes: citationsAnswerData, encoding: .utf8))
    try CrossModeStubURLProtocol.register(
        url: citationsEndpoint, status: 200,
        body: makeEnvelope(contentBlocks: [
            ["type": "text", "text": citationsAnswer],
            ["type": "text", "text": "", "citations": [["start_block_index": 0, "end_block_index": 1]]],
            ["type": "text", "text": "", "citations": [["start_block_index": 1, "end_block_index": 2]]],
        ]),
    )
    let citationsSummarizer = ClaudeCitationsSummarizer(httpClient: makeHTTPClient(endpoint: citationsEndpoint))
    let citationsResult = try await citationsSummarizer.summarize(
        transcript: transcript, glossary: Glossary(), config: SummarizerConfig(),
    )

    #expect(substringResult.groundingMethod == .substring)
    #expect(citationsResult.groundingMethod == .citations)

    let substringRendered = try (substringResult.actionItems + substringResult.decisions).map { try render($0, transcript: transcript) }
    let citationsRendered = try (citationsResult.actionItems + citationsResult.decisions).map { try render($0, transcript: transcript) }
    #expect(substringRendered == citationsRendered)
}
