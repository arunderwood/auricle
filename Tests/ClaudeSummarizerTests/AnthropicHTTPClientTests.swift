@testable import ClaudeSummarizer
import Core
import Foundation
import SummarizerInterface
import Testing

// MARK: - URLProtocol stub

/// Intercepts every request made through a session configured with this
/// class registered as its sole `protocolClasses` entry — no real network
/// call ever leaves the process. Tests are identified by a per-test UUID
/// carried in the `X-Test-Token` header (rather than by URL or by a single
/// shared queue) so concurrently-run tests in this file can't cross-talk
/// through this type's necessarily-static Foundation-mandated state.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Responder = @Sendable (_ attemptIndex: Int) -> Response

    enum Response {
        case http(status: Int, body: Data)
        case failure(URLError)
    }

    static let tokenHeader = "X-Test-Token"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var responders: [String: Responder] = [:]
    private nonisolated(unsafe) static var attemptCounts: [String: Int] = [:]
    private nonisolated(unsafe) static var lastHeaders: [String: [String: String]] = [:]

    static func register(token: String, responder: @escaping Responder) {
        lock.lock()
        responders[token] = responder
        attemptCounts[token] = 0
        lock.unlock()
    }

    static func unregister(token: String) {
        lock.lock()
        responders.removeValue(forKey: token)
        attemptCounts.removeValue(forKey: token)
        lastHeaders.removeValue(forKey: token)
        lock.unlock()
    }

    static func attemptCount(for token: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptCounts[token] ?? 0
    }

    /// The headers `AnthropicHTTPClient` actually sent on the most recent
    /// attempt for `token` — lets a test assert on final, post-precedence
    /// header values rather than only on the response side of the exchange.
    static func lastRequestHeader(for token: String, field: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastHeaders[token]?[field]
    }

    private static func recordHeaders(_ headers: [String: String], for token: String) {
        lock.lock()
        lastHeaders[token] = headers
        lock.unlock()
    }

    private static func recordAttempt(for token: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = attemptCounts[token] ?? 0
        attemptCounts[token] = index + 1
        return index
    }

    private static func behavior(for token: String) -> Responder? {
        lock.lock()
        defer { lock.unlock() }
        return responders[token]
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: Self.tokenHeader) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        Self.recordHeaders(request.allHTTPHeaderFields ?? [:], for: token)
        let index = Self.recordAttempt(for: token)
        let response = Self.behavior(for: token)?(index) ?? .failure(URLError(.unknown))

        switch response {
        case let .http(status, body):
            guard
                let url = request.url,
                let httpResponse = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(urlError):
            client?.urlProtocol(self, didFailWithError: urlError)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test support

/// Records the durations `AnthropicHTTPClient` asks its injected `sleep`
/// function to wait, without ever actually waiting — an actor so
/// concurrent access from the client's `Sendable` closure is race-free.
private actor DelaySpy {
    private(set) var recordedDelays: [Duration] = []

    func record(_ delay: Duration) {
        recordedDelays.append(delay)
    }
}

private func makeClient(
    apiKey: String = "test-key",
    backoffSchedule: [Duration] = AnthropicHTTPClient.defaultBackoffSchedule,
    totalRetryBudget: Duration = AnthropicHTTPClient.defaultRetryBudget,
    sleep: @escaping AnthropicHTTPClient.SleepFunction = { _ in },
) -> AnthropicHTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return AnthropicHTTPClient(
        session: URLSession(configuration: configuration),
        apiKeyProvider: { apiKey },
        backoffSchedule: backoffSchedule,
        totalRetryBudget: totalRetryBudget,
        sleep: sleep,
    )
}

private func makeRequest(token: String) -> AnthropicRequest {
    AnthropicRequest(body: Data("{}".utf8), headers: [StubURLProtocol.tokenHeader: token])
}

private func validEnvelopeJSON(
    model: String = "claude-opus-5",
    contentText: String = "hello",
    cacheCreationInputTokens: Int = 0,
    cacheReadInputTokens: Int = 0,
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "id": "msg_01ABC",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": [["type": "text", "text": contentText]],
        "stop_reason": "end_turn",
        "usage": [
            "input_tokens": 100,
            "output_tokens": 50,
            "cache_creation_input_tokens": cacheCreationInputTokens,
            "cache_read_input_tokens": cacheReadInputTokens,
        ],
    ])
}

private func errorEnvelopeJSON(message: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "error",
        "error": ["type": "invalid_request_error", "message": message],
    ])
}

// MARK: - Successful request

@Test func successfulRequestReturnsDecodedResponseWithNoRetry() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    let body = try validEnvelopeJSON(cacheCreationInputTokens: 7, cacheReadInputTokens: 3)
    StubURLProtocol.register(token: token) { _ in .http(status: 200, body: body) }
    let spy = DelaySpy()
    let client = makeClient(sleep: { await spy.record($0) })

    let response = try await client.send(makeRequest(token: token))

    #expect(response.model == "claude-opus-5")
    #expect(response.usage.inputTokens == 100)
    #expect(response.usage.outputTokens == 50)
    #expect(response.usage.cacheCreationInputTokens == 7)
    #expect(response.usage.cacheReadInputTokens == 3)
    #expect(response.stopReason == "end_turn")
    // 100 input / 50 output tokens at claude-opus-5's $5/$25 per-MTok rate.
    #expect(abs(response.costUSD - 0.00175) < 0.0000001)
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
    #expect(await spy.recordedDelays.isEmpty)

    let decodedContent = try JSONSerialization.jsonObject(with: response.content) as? [[String: String]]
    #expect(decodedContent == [["type": "text", "text": "hello"]])
}

@Test func unrecognizedModelIdentifierPricesAtTheClaudeOpusFiveFallbackRate() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    let body = try validEnvelopeJSON(model: "claude-some-future-model")
    StubURLProtocol.register(token: token) { _ in .http(status: 200, body: body) }
    let client = makeClient()

    let response = try await client.send(makeRequest(token: token))

    #expect(response.model == "claude-some-future-model")
    #expect(abs(response.costUSD - 0.00175) < 0.0000001)
}

// MARK: - Transient rate limit

@Test func rateLimitedTwiceThenSuccessRetriesWithDocumentedBackoffThenSucceeds() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    let body = try validEnvelopeJSON()
    StubURLProtocol.register(token: token) { attemptIndex in
        attemptIndex < 2 ? .http(status: 429, body: Data()) : .http(status: 200, body: body)
    }
    let spy = DelaySpy()
    let client = makeClient(sleep: { await spy.record($0) })

    let response = try await client.send(makeRequest(token: token))

    #expect(response.model == "claude-opus-5")
    #expect(StubURLProtocol.attemptCount(for: token) == 3)
    #expect(await spy.recordedDelays == [.seconds(1), .seconds(2)])
}

// MARK: - Persistent 5xx

@Test func persistentServerErrorRetriesUntilBudgetExhaustedThenThrowsRateLimited() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .http(status: 500, body: Data()) }
    let client = makeClient(
        backoffSchedule: [.milliseconds(1), .milliseconds(2), .milliseconds(4)],
        totalRetryBudget: .milliseconds(5),
        sleep: { _ in },
    )

    await #expect(throws: SummarizerError.rateLimited) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 3)
}

// MARK: - Persistent network timeout

@Test func persistentNetworkTimeoutRetriesUntilBudgetExhaustedThenThrowsNetworkTimeout() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .failure(URLError(.timedOut)) }
    let client = makeClient(
        backoffSchedule: [.milliseconds(1), .milliseconds(2), .milliseconds(4)],
        totalRetryBudget: .milliseconds(5),
        sleep: { _ in },
    )

    await #expect(throws: SummarizerError.networkTimeout) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 3)
}

// MARK: - Auth / billing failures (no retry)

@Test func authFailureThrowsImmediatelyWithNoRetry() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .http(status: 401, body: Data()) }
    let spy = DelaySpy()
    let client = makeClient(sleep: { await spy.record($0) })

    await #expect(throws: SummarizerError.authenticationFailed) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
    #expect(await spy.recordedDelays.isEmpty)
}

@Test func billingFailureThrowsImmediatelyWithNoRetry() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .http(status: 402, body: Data()) }
    let spy = DelaySpy()
    let client = makeClient(sleep: { await spy.record($0) })

    await #expect(throws: SummarizerError.quotaExceeded) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
    #expect(await spy.recordedDelays.isEmpty)
}

@Test func creditBalanceFourHundredThrowsQuotaExceededWithNoRetry() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    let body = try errorEnvelopeJSON(
        message: "Your credit balance is too low to access the Anthropic API. "
            + "Please go to Plans & Billing to upgrade or purchase credits.",
    )
    StubURLProtocol.register(token: token) { _ in .http(status: 400, body: body) }
    let spy = DelaySpy()
    let client = makeClient(sleep: { await spy.record($0) })

    await #expect(throws: SummarizerError.quotaExceeded) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
    #expect(await spy.recordedDelays.isEmpty)
}

@Test func creditBalanceMatchIsCaseInsensitive() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    let body = try errorEnvelopeJSON(message: "YOUR CREDIT BALANCE IS TOO LOW")
    StubURLProtocol.register(token: token) { _ in .http(status: 400, body: body) }
    let client = makeClient()

    await #expect(throws: SummarizerError.quotaExceeded) {
        _ = try await client.send(makeRequest(token: token))
    }
}

// MARK: - Malformed / other 4xx (no retry)

@Test func otherFourHundredStatusThrowsMalformedResponseWithNoRetry() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .http(status: 400, body: Data()) }
    let client = makeClient()

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
}

@Test func unrelatedFourHundredWithAnErrorBodyStillThrowsMalformedResponse() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    let body = try errorEnvelopeJSON(message: "max_tokens: must be greater than 0")
    StubURLProtocol.register(token: token) { _ in .http(status: 400, body: body) }
    let client = makeClient()

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
}

@Test func nonJSONFourHundredBodyMentioningCreditBalanceStillThrowsMalformedResponse() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .http(status: 400, body: Data("credit balance".utf8)) }
    let client = makeClient()

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await client.send(makeRequest(token: token))
    }
}

// MARK: - Malformed 200 body

@Test func twoHundredStatusWithAnUndecodableBodyThrowsMalformedResponseWithNoRetry() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .http(status: 200, body: Data("{}".utf8)) }
    let client = makeClient()

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
}

@Test func twoHundredStatusWithANonSerializableContentValueThrowsMalformedResponse() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "claude-opus-5",
        "content": NSNull(),
        "stop_reason": "end_turn",
        "usage": ["input_tokens": 100, "output_tokens": 50],
    ])
    StubURLProtocol.register(token: token) { _ in .http(status: 200, body: body) }
    let client = makeClient()

    await #expect(throws: SummarizerError.malformedResponse) {
        _ = try await client.send(makeRequest(token: token))
    }
}

// MARK: - Truncated response

@Test func aResponseThatStoppedAtMaxTokensThrowsResponseTruncatedWithNoRetry() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "claude-opus-5",
        "content": [["type": "text", "text": "{\"summary\": \"Team discussed the lau"]],
        "stop_reason": "max_tokens",
        "usage": ["input_tokens": 100, "output_tokens": 16384],
    ])
    StubURLProtocol.register(token: token) { _ in .http(status: 200, body: body) }
    let client = makeClient()

    await #expect(throws: SummarizerError.responseTruncated) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
}

@Test func otherStopReasonsAreNotTruncation() async throws {
    for stopReason in ["end_turn", "stop_sequence", "tool_use"] {
        let token = UUID().uuidString
        defer { StubURLProtocol.unregister(token: token) }
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-5",
            "content": [["type": "text", "text": "hello"]],
            "stop_reason": stopReason,
            "usage": ["input_tokens": 100, "output_tokens": 50],
        ])
        StubURLProtocol.register(token: token) { _ in .http(status: 200, body: body) }

        let response = try await makeClient().send(makeRequest(token: token))

        #expect(response.stopReason == stopReason)
    }
}

// MARK: - Header precedence

@Test func callerSuppliedHeadersCannotOverrideTheRealAPIKeyHeader() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    let body = try validEnvelopeJSON()
    StubURLProtocol.register(token: token) { _ in .http(status: 200, body: body) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = AnthropicHTTPClient(
        session: URLSession(configuration: configuration),
        apiKeyProvider: { "real-key" },
        sleep: { _ in },
    )
    let request = AnthropicRequest(
        body: Data("{}".utf8),
        headers: [StubURLProtocol.tokenHeader: token, "x-api-key": "attacker-supplied-key"],
    )

    _ = try await client.send(request)

    #expect(StubURLProtocol.lastRequestHeader(for: token, field: "x-api-key") == "real-key")
}

// MARK: - Retry plateau

@Test func retryLoopHoldsAtTheFinalScheduleStepForRetriesBeyondTheSchedulesLength() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .http(status: 500, body: Data()) }
    let spy = DelaySpy()
    let client = makeClient(
        backoffSchedule: [.milliseconds(1), .milliseconds(2)],
        totalRetryBudget: .milliseconds(20),
        sleep: { await spy.record($0) },
    )

    await #expect(throws: SummarizerError.rateLimited) {
        _ = try await client.send(makeRequest(token: token))
    }

    let delays = await spy.recordedDelays
    // Schedule is [1ms, 2ms]; every retry past the 2nd holds at the final
    // (2ms) step rather than continuing to escalate or resetting.
    #expect(delays.count > 2)
    #expect(delays.dropFirst(2).allSatisfy { $0 == .milliseconds(2) })
}

// MARK: - Cancellation mid-retry

@Test func cancellationDuringABackoffSleepPropagatesRatherThanRetrying() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .http(status: 429, body: Data()) }
    let client = makeClient(sleep: { _ in throw CancellationError() })

    await #expect(throws: CancellationError.self) {
        _ = try await client.send(makeRequest(token: token))
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
}

@Test func cancelledURLErrorFromTheSessionPropagatesRatherThanConvertingToNetworkTimeout() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    StubURLProtocol.register(token: token) { _ in .failure(URLError(.cancelled)) }
    let client = makeClient()

    // Not `#expect(throws: URLError(.cancelled))`: the real error URLSession
    // delivers carries extra userInfo (task references) that never matches
    // a bare `URLError(.cancelled)` by full equality, even though `.code`
    // does — so this checks `.code` directly instead.
    do {
        _ = try await client.send(makeRequest(token: token))
        Issue.record("Expected URLError(.cancelled) to be thrown")
    } catch let urlError as URLError {
        #expect(urlError.code == .cancelled)
    } catch {
        Issue.record("Expected URLError(.cancelled), got \(error)")
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 1)
}

@Test func cancelledURLErrorPropagatesEvenWhenTheRetryBudgetIsAlreadyExhausted() async throws {
    let token = UUID().uuidString
    defer { StubURLProtocol.unregister(token: token) }
    // Attempt 0 consumes the entire (tiny) budget via an ordinary retryable
    // network failure; attempt 1 — the one `send()` would otherwise
    // terminate with `.networkTimeout` — is cancelled instead. Cancellation
    // must still win, not be coerced into the exhaustion path.
    StubURLProtocol.register(token: token) { attemptIndex in
        attemptIndex == 0 ? .failure(URLError(.timedOut)) : .failure(URLError(.cancelled))
    }
    let client = makeClient(
        backoffSchedule: [.milliseconds(1)],
        totalRetryBudget: .milliseconds(1),
        sleep: { _ in },
    )

    do {
        _ = try await client.send(makeRequest(token: token))
        Issue.record("Expected URLError(.cancelled) to be thrown")
    } catch let urlError as URLError {
        #expect(urlError.code == .cancelled)
    } catch {
        Issue.record("Expected URLError(.cancelled), got \(error)")
    }
    #expect(StubURLProtocol.attemptCount(for: token) == 2)
}

// MARK: - Redaction

@Test func redactedLogFieldsNeverContainTheResponseBodyMarker() {
    let marker = "DISTINCTIVE-MARKER-\(UUID().uuidString)"
    let response = AnthropicResponse(
        model: "claude-opus-5",
        stopReason: "end_turn",
        usage: .init(inputTokens: 10, outputTokens: 20, cacheCreationInputTokens: 0, cacheReadInputTokens: 0),
        thinkingTokens: 0,
        costUSD: 0.0042,
        content: Data(marker.utf8),
    )

    let fields = AnthropicHTTPClient.redactedLogFields(for: response, statusCode: 200)

    #expect(fields.count == 6)
    for (_, value) in fields {
        switch value {
        case let .publicSafe(rendered):
            #expect(!rendered.contains(marker))
        case let .sensitive(rendered):
            #expect(!rendered.contains(marker))
        }
    }
}
