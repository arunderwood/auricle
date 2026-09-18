import Core
import Foundation
import SummarizerInterface

/// A caller-supplied request to the Anthropic Messages API: the raw JSON
/// body plus any headers beyond the ones every request already carries
/// (`x-api-key`, `anthropic-version`, `content-type`). Body-shape-agnostic
/// by design — building the Citations/substring content-block wire format
/// is Story 3.4/3.5's job, not this client's.
public struct AnthropicRequest: Sendable, Equatable {
    public let body: Data
    public let headers: [String: String]

    public init(body: Data, headers: [String: String] = [:]) {
        self.body = body
        self.headers = headers
    }
}

/// The Messages API's standard response envelope, decoded just far enough
/// to be useful to every caller: `model`, `usage`, `stopReason`, and a
/// derived `costUSD`. `content` is carried through as undecoded JSON bytes
/// — no strategy's wire format (Citations blocks, substring quotes) is
/// known at this layer, so this client never attempts to parse it.
public struct AnthropicResponse: Sendable, Equatable {
    public struct Usage: Sendable, Equatable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheCreationInputTokens: Int
        public let cacheReadInputTokens: Int
    }

    public let model: String
    public let stopReason: String?
    public let usage: Usage
    /// `0` unless a future `usage` payload carries a distinct thinking-token
    /// count — today's Messages API bundles thinking tokens into
    /// `output_tokens`, so this is never a fabricated estimate.
    public let thinkingTokens: Int
    public let costUSD: Double
    /// Opaque passthrough of the response's `content` array, re-serialized
    /// to its own JSON bytes. Story 3.4/3.5 decode this into their own
    /// Citations/substring shapes; this client never inspects it.
    public let content: Data

    static func parse(_ data: Data) throws -> AnthropicResponse {
        guard
            let raw = try? JSONSerialization.jsonObject(with: data),
            let json = raw as? [String: Any],
            let model = json["model"] as? String,
            let usageJSON = json["usage"] as? [String: Any],
            let inputTokens = usageJSON["input_tokens"] as? Int,
            let outputTokens = usageJSON["output_tokens"] as? Int,
            inputTokens >= 0, outputTokens >= 0
        else {
            throw SummarizerError.malformedResponse
        }

        let usage = Usage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: usageJSON["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadInputTokens: usageJSON["cache_read_input_tokens"] as? Int ?? 0,
        )

        let content: Data
        if let contentValue = json["content"] {
            // `JSONSerialization.data(withJSONObject:)` raises an uncatchable
            // Objective-C exception (not a Swift error `try?` can absorb)
            // when its top-level argument isn't itself an Array or
            // Dictionary — `isValidJSONObject` must gate the call, not just
            // wrap it, or a bare scalar/null `content` value crashes the
            // process instead of surfacing as `.malformedResponse`.
            guard
                JSONSerialization.isValidJSONObject(contentValue),
                let serialized = try? JSONSerialization.data(withJSONObject: contentValue)
            else {
                throw SummarizerError.malformedResponse
            }
            content = serialized
        } else {
            content = Data()
        }

        return AnthropicResponse(
            model: model,
            stopReason: json["stop_reason"] as? String,
            usage: usage,
            thinkingTokens: usageJSON["thinking_tokens"] as? Int ?? 0,
            costUSD: AnthropicModelRate.costUSD(model: model, inputTokens: inputTokens, outputTokens: outputTokens),
            content: content,
        )
    }
}

/// Stand-in per-model USD/MTok rate table (decision-record-2026-09-16's
/// "own computation, rate table, auditable and fixable" ruling): no
/// config-loading component exists yet anywhere in this codebase, so this
/// hard-coded, maintainer-editable table stands in until a real config
/// story lands. Cache read/write tokens are parsed into `Usage` for
/// telemetry but aren't priced here — only published per-model input/output
/// rates are.
private enum AnthropicModelRate {
    static let fallbackModel = "claude-opus-5"

    private static let usdPerMillionTokens: [String: (input: Double, output: Double)] = [
        "claude-opus-5": (input: 15.0, output: 75.0),
        "claude-haiku-4-5": (input: 1.0, output: 5.0),
    ]

    static func costUSD(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let rate = usdPerMillionTokens[model] ?? usdPerMillionTokens[fallbackModel] ?? (input: 0, output: 0)
        let million = 1_000_000.0
        return (Double(inputTokens) / million * rate.input) + (Double(outputTokens) / million * rate.output)
    }
}

/// Shared HTTP layer for every Anthropic caller (`ClaudeCitationsSummarizer`,
/// `ClaudeSubstringSummarizer`, and eventually `ClaudeAIReviewers`):
/// `URLSession` transport, TLS 1.2+, retry/backoff with a total time
/// budget, HTTP-status-to-`SummarizerError` mapping, and redacted logging.
///
/// An instance, not an actor: unlike `SummarizerOrchestrator`, no mutable
/// state is shared across concurrent `send(_:)` calls, so plain `Sendable`
/// value semantics are enough. The schedule, sleep primitive, session, and
/// API-key source are all constructor-injected — the same shape
/// `RetentionScheduler` uses for its `interval`/`now` closures — so tests
/// exercise real retry logic without waiting in real time or touching the
/// network or the real Keychain.
public struct AnthropicHTTPClient: Sendable {
    public typealias APIKeyProvider = @Sendable () throws -> String
    public typealias SleepFunction = @Sendable (Duration) async throws -> Void

    /// Escalates 1s -> 2s -> 4s -> 8s -> 16s, then (per `send(_:)`) holds at
    /// the final step for any further retry until the total budget below is
    /// exhausted — the "cap, not floor" reading of Decision 4.2's budget.
    public static let defaultBackoffSchedule: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]
    /// NFR-R9's default total retry-time budget.
    public static let defaultRetryBudget: Duration = .seconds(300)
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private enum AttemptOutcome {
        case success(AnthropicResponse)
        case retryable(RetryReason)
        case terminal(SummarizerError)
    }

    private enum RetryReason {
        case http
        case network
    }

    private let session: URLSession
    private let endpoint: URL
    private let apiKeyProvider: APIKeyProvider
    private let backoffSchedule: [Duration]
    private let totalRetryBudget: Duration
    private let sleep: SleepFunction
    private let log = Log(category: "claude-summarizer")

    public init(
        session: URLSession = AnthropicHTTPClient.makeDefaultSession(),
        endpoint: URL = AnthropicHTTPClient.defaultEndpoint,
        apiKeyProvider: @escaping APIKeyProvider = { try KeychainAPIKey.read() },
        backoffSchedule: [Duration] = AnthropicHTTPClient.defaultBackoffSchedule,
        totalRetryBudget: Duration = AnthropicHTTPClient.defaultRetryBudget,
        sleep: @escaping SleepFunction = { try await Task.sleep(for: $0) },
    ) {
        precondition(!backoffSchedule.isEmpty, "backoffSchedule must not be empty")
        self.session = session
        self.endpoint = endpoint
        self.apiKeyProvider = apiKeyProvider
        self.backoffSchedule = backoffSchedule
        self.totalRetryBudget = totalRetryBudget
        self.sleep = sleep
    }

    /// `.ephemeral` so this client never leaves cookies or cached
    /// credentials on disk — consistent with the Keychain-only,
    /// call-scoped handling of the API key itself (NFR-S1).
    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration)
    }

    /// Reads the API key once, covering every retry this call makes, then
    /// retries per the injected schedule/budget until a terminal outcome:
    /// success, a non-retryable HTTP status, or budget exhaustion.
    /// Cancellation (`CancellationError` from the injected `sleep`,
    /// `URLError(.cancelled)` from `URLSession`) is never caught here as a
    /// retryable failure — it propagates straight out of this loop.
    public func send(_ request: AnthropicRequest) async throws -> AnthropicResponse {
        let apiKey = try apiKeyProvider()
        let urlRequest = buildURLRequest(request, apiKey: apiKey)

        var elapsedRetryTime: Duration = .zero
        var retryIndex = 0

        while true {
            switch try await performAttempt(urlRequest) {
            case let .success(response):
                return response
            case let .terminal(error):
                throw error
            case let .retryable(reason):
                let delay = backoffSchedule[min(retryIndex, backoffSchedule.count - 1)]
                guard elapsedRetryTime + delay <= totalRetryBudget else {
                    throw reason == .network ? SummarizerError.networkTimeout : SummarizerError.rateLimited
                }
                try await sleep(delay)
                elapsedRetryTime += delay
                retryIndex += 1
            }
        }
    }

    private func performAttempt(_ urlRequest: URLRequest) async throws -> AttemptOutcome {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let cancellationError as CancellationError {
            throw cancellationError
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw urlError
        } catch {
            log.warn("anthropic request failed at the network layer, retrying", ["error": .publicSafe(String(describing: error))])
            return .retryable(.network)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .terminal(.malformedResponse)
        }
        return outcome(forStatusCode: httpResponse.statusCode, data: data)
    }

    private func outcome(forStatusCode statusCode: Int, data: Data) -> AttemptOutcome {
        switch statusCode {
        case 200 ..< 300:
            guard let parsed = try? AnthropicResponse.parse(data) else {
                return .terminal(.malformedResponse)
            }
            log.info("anthropic request succeeded", Self.redactedLogFields(for: parsed, statusCode: statusCode))
            return .success(parsed)
        case 401, 403:
            log.warn("anthropic request failed authentication", ["statusCode": .publicSafe(statusCode)])
            return .terminal(.authenticationFailed)
        case 402:
            log.warn("anthropic request failed billing check", ["statusCode": .publicSafe(statusCode)])
            return .terminal(.quotaExceeded)
        case 429, 500 ... 599:
            log.warn("anthropic request failed, retrying", ["statusCode": .publicSafe(statusCode)])
            return .retryable(.http)
        default:
            log.warn("anthropic request returned an unhandled status", ["statusCode": .publicSafe(statusCode)])
            return .terminal(.malformedResponse)
        }
    }

    private func buildURLRequest(_ request: AnthropicRequest, apiKey: String) -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        // Set after the caller's own headers so a caller-supplied header
        // reusing one of these names can never shadow the real credential
        // or protocol version.
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        return urlRequest
    }

    /// Pure, internally-testable field construction, mirroring how
    /// `Log.buildMessage` itself is unit-tested directly: this function's
    /// parameters carry only status code, token counts, cost, and model —
    /// the response body/`content` never has a path into this call at all,
    /// so the "never logged" guarantee holds by construction, not by
    /// discipline at each call site.
    static func redactedLogFields(for response: AnthropicResponse, statusCode: Int) -> [String: LogSensitivity] {
        [
            "statusCode": .publicSafe(statusCode),
            "model": .publicSafe(response.model),
            "inputTokens": .publicSafe(response.usage.inputTokens),
            "outputTokens": .publicSafe(response.usage.outputTokens),
            "thinkingTokens": .publicSafe(response.thinkingTokens),
            "costUSD": .publicSafe(response.costUSD),
        ]
    }
}
