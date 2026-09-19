import ClaudeSummarizer
import Core
import Foundation

// MARK: - HTTP stub

/// Serves one canned 200 body per endpoint URL. The request body is never
/// read, so nothing the strategies put in a prompt can change what comes back.
final class EvalStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var bodies: [URL: Data] = [:]
    private nonisolated(unsafe) static var requestCounts: [URL: Int] = [:]

    static func register(url: URL, body: Data) {
        lock.lock()
        bodies[url] = body
        requestCounts[url] = 0
        lock.unlock()
    }

    static func unregister(url: URL) {
        lock.lock()
        bodies.removeValue(forKey: url)
        requestCounts.removeValue(forKey: url)
        lock.unlock()
    }

    static func requestCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[url] ?? 0
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
        let body = Self.bodies[url]
        Self.requestCounts[url, default: 0] += 1
        Self.lock.unlock()

        guard
            let body,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// An `AnthropicHTTPClient` wired to a private endpoint that answers every
/// request with one fixed body and counts the requests it receives. The
/// endpoint is unique per instance, so tests running in parallel never read
/// each other's stub.
struct EvalStub {
    let client: AnthropicHTTPClient
    private let endpoint: URL

    init(response body: Data) {
        let endpoint = URL(string: "https://eval-stub.invalid/\(UUID().uuidString)")!
        EvalStubURLProtocol.register(url: endpoint, body: body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EvalStubURLProtocol.self]
        self.endpoint = endpoint
        client = AnthropicHTTPClient(
            session: URLSession(configuration: configuration),
            endpoint: endpoint,
            apiKeyProvider: { "test-key" },
            sleep: { _ in },
        )
    }

    var requestCount: Int {
        EvalStubURLProtocol.requestCount(for: endpoint)
    }

    func release() {
        EvalStubURLProtocol.unregister(url: endpoint)
    }
}

// MARK: - Decoys

enum EvalSection: String {
    case actionItems = "action_items"
    case decisions
}

/// An item the substring stub emits that the transcript cannot ground. The
/// validator has to drop it; keeping it is the failure this exists to catch.
struct EvalDecoy: Equatable {
    let section: EvalSection
    let text: String
    let quote: String
}

enum EvalStubError: Error, CustomStringConvertible {
    case noOwnerUtterance(itemText: String)
    case noAbsentDecoyQuote
    case unencodableJSON

    var description: String {
        switch self {
        case let .noOwnerUtterance(itemText):
            "no utterance contains the expected quote for '\(itemText)'"
        case .noAbsentDecoyQuote:
            "every decoy sentence already occurs in the transcript"
        case .unencodableJSON:
            "a stub payload was not valid JSON"
        }
    }
}

// MARK: - Response builders

/// Builds Messages API response bodies as a pure function of a fixture:
/// nothing here reads a prompt, a clock or a random source, so the same
/// fixture always yields the same bytes.
enum EvalStubResponses {
    static let summaryText = "Frozen eval summary."

    /// Absent from every fixture transcript by construction; `decoys(for:)`
    /// still proves it per transcript instead of trusting that.
    private static let decoyQuoteCandidates = [
        "The steering committee approved relocating the whole team to a lunar base by Tuesday.",
        "Purple elephants will audit the quarterly submarine budget.",
        "Everyone agreed to rename the company after the office cat.",
        "Nobody objected to airlifting the servers by hot air balloon.",
    ]

    /// One decoy per section. Each quote is checked with a case-insensitive
    /// search, which is looser than the validator's own literal one, so a
    /// quote that passes here cannot be found by the validator either.
    static func decoys(for transcript: CanonicalTranscript) throws -> [EvalDecoy] {
        let haystack = transcript.text.lowercased()
        let absent = decoyQuoteCandidates.filter { !haystack.contains($0.lowercased()) }
        guard absent.count >= 2 else { throw EvalStubError.noAbsentDecoyQuote }
        return [
            EvalDecoy(section: .actionItems, text: "Decoy action item", quote: absent[0]),
            EvalDecoy(section: .decisions, text: "Decoy decision", quote: absent[1]),
        ]
    }

    /// The Citations shape: a JSON answer in the first text block, then one
    /// citation-bearing block per item (action items first), each citing the
    /// utterance that holds the item's quote. `end_block_index` is exclusive.
    static func citations(for fixture: EvalFixture) throws -> Data {
        let expected = fixture.expected
        let actionBlocks = try expected.actionItems.map { try ownerBlockIndex(of: $0, in: fixture.transcript) }
        let decisionBlocks = try expected.decisions.map { try ownerBlockIndex(of: $0, in: fixture.transcript) }

        func answerItems(_ items: [EvalExpectedItem], _ blocks: [Int]) -> [[String: Any]] {
            zip(items, blocks).map { ["text": $0.text, "source_block_index": $1] }
        }
        let answer = try jsonString([
            "summary": summaryText,
            "action_items": answerItems(expected.actionItems, actionBlocks),
            "decisions": answerItems(expected.decisions, decisionBlocks),
        ])

        let answerBlock: [String: Any] = ["type": "text", "text": answer]
        let citationBlocks: [[String: Any]] = (actionBlocks + decisionBlocks).map {
            ["type": "text", "text": "", "citations": [["start_block_index": $0, "end_block_index": $0 + 1]]]
        }
        return try envelope(contentBlocks: [answerBlock] + citationBlocks)
    }

    /// The substring shape: one JSON answer whose items each carry a verbatim
    /// quote. Every expected item is followed, within its section, by that
    /// section's decoy when one is given.
    static func substring(for fixture: EvalFixture, decoys: [EvalDecoy]) throws -> Data {
        func answerItems(_ section: EvalSection, _ expected: [EvalExpectedItem]) -> [[String: String]] {
            let real = expected.map { ["text": $0.text, "source_transcript_quote": $0.quote] }
            let invented = decoys
                .filter { $0.section == section }
                .map { ["text": $0.text, "source_transcript_quote": $0.quote] }
            return real + invented
        }
        let answer = try jsonString([
            "summary": summaryText,
            "action_items": answerItems(.actionItems, fixture.expected.actionItems),
            "decisions": answerItems(.decisions, fixture.expected.decisions),
        ])
        return try envelope(contentBlocks: [["type": "text", "text": answer]])
    }

    // MARK: Private

    private static func ownerBlockIndex(of item: EvalExpectedItem, in transcript: CanonicalTranscript) throws -> Int {
        guard let index = transcript.utterances.firstIndex(where: { $0.start <= item.transcriptStart && item.transcriptEnd <= $0.end }) else {
            throw EvalStubError.noOwnerUtterance(itemText: item.text)
        }
        return index
    }

    private static func envelope(contentBlocks: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-opus-5",
                "content": contentBlocks,
                "stop_reason": "end_turn",
                "usage": ["input_tokens": 100, "output_tokens": 50],
            ] as [String: Any],
            options: [.sortedKeys],
        )
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(bytes: data, encoding: .utf8) else { throw EvalStubError.unencodableJSON }
        return text
    }
}
