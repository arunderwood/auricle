import AIReviewerInterface
import ClaudeAIReviewers
import ClaudeSummarizer
import Core
import DiarizerInterface
import Foundation

/// One canned response per test, keyed by a per-test unique endpoint URL.
final class ReviewerStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responses: [URL: (status: Int, body: Data)] = [:]
    private nonisolated(unsafe) static var capturedBodies: [URL: Data] = [:]

    static func register(url: URL, status: Int, body: Data) {
        lock.lock()
        responses[url] = (status, body)
        lock.unlock()
    }

    static func capturedBody(for url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies[url]
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private static func bodyData(from request: URLRequest) -> Data? {
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

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let body = Self.bodyData(from: request)
        Self.lock.lock()
        if let body {
            Self.capturedBodies[url] = body
        }
        let response = Self.responses[url]
        Self.lock.unlock()

        guard
            let response,
            let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum ReviewerTestSupport {
    static func uniqueEndpoint() -> URL {
        URL(string: "https://stub.invalid/\(UUID().uuidString)")!
    }

    static func makeReviewer(endpoint: URL) -> ClaudeDiarizationReviewer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewerStubURLProtocol.self]
        return ClaudeDiarizationReviewer(httpClient: AnthropicHTTPClient(
            session: URLSession(configuration: configuration),
            endpoint: endpoint,
            apiKeyProvider: { "test-key" },
            sleep: { _ in },
        ))
    }

    static func makeInput() -> DiarizationReviewInput {
        let text = "Speaker_1: Hello there.\nSpeaker_2: Hi, thanks for joining."
        let transcript = CanonicalTranscript(text: text, utterances: [
            .init(speakerLabel: "Speaker_1", start: 0, end: 23),
            .init(speakerLabel: "Speaker_2", start: 24, end: 56),
        ])
        let diarization = DiarizationArtifact(segments: [
            .init(id: "seg_1", speakerLabel: "Speaker_1", startSeconds: 0, endSeconds: 2, utteranceIndex: .init(first: 0, last: 0), voiceProfile: .init(overlapRatio: 0)),
            .init(id: "seg_2", speakerLabel: "Speaker_2", startSeconds: 2, endSeconds: 5, utteranceIndex: .init(first: 1, last: 1), voiceProfile: .init(overlapRatio: 0.1)),
        ])
        return DiarizationReviewInput(transcript: transcript, diarization: diarization)
    }

    /// A 200 response whose one text block holds `answer`.
    static func responseBody(answer: String, model: String = "claude-haiku-4-5", input: Int = 1000, output: Int = 200) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "stop_reason": "end_turn",
            "usage": ["input_tokens": input, "output_tokens": output],
            "content": [["type": "text", "text": answer]],
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func run(answer: String, endpoint: URL = uniqueEndpoint(), model: String = "claude-haiku-4-5") async throws -> AIReviewerResult<DiarizationSuggestion> {
        try ReviewerStubURLProtocol.register(url: endpoint, status: 200, body: responseBody(answer: answer))
        return try await makeReviewer(endpoint: endpoint).review(input: makeInput(), config: AIReviewerConfig(modelID: model))
    }
}
