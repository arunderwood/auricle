import CalendarInterface
import Foundation
@testable import GoogleCalendarSource

// MARK: - Recorded traffic

struct RecordedRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data

    /// The `application/x-www-form-urlencoded` body as name/value pairs.
    var form: [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = (String(bytes: body, encoding: .utf8) ?? "")
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    var query: [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    var bearerToken: String? {
        headers["Authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst("Bearer ".count)) : nil }
    }
}

enum StubReply: Sendable {
    case http(status: Int, body: Data)
    case failure(URLError)

    static func json(_ status: Int, _ object: Any) -> StubReply {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .http(status: status, body: body)
    }

    static func text(_ status: Int, _ body: String) -> StubReply {
        .http(status: status, body: Data(body.utf8))
    }
}

// MARK: - Stub

/// A stand-in for Google's authorization, token and Calendar endpoints. Every
/// stub owns a unique URL prefix, so tests running in parallel never see each
/// other's traffic; nothing here leaves the process.
final class GoogleStub: @unchecked Sendable {
    /// `(request, indexAmongRequestsToThisEndpoint)`.
    typealias Responder = @Sendable (RecordedRequest, Int) -> StubReply

    static let defaultToken: Responder = { _, index in
        .json(200, ["access_token": "access-\(index + 1)", "expires_in": 3600])
    }

    static let emptyEvents: Responder = { _, _ in .json(200, ["items": [Any]()]) }

    let endpoints: GoogleEndpoints
    let session: URLSession

    private let id = UUID().uuidString
    private let token: Responder
    private let events: Responder
    private let lock = NSLock()
    private var recorded: [RecordedRequest] = []

    init(token: @escaping Responder = GoogleStub.defaultToken, events: @escaping Responder = GoogleStub.emptyEvents) {
        let base = "https://google-stub.invalid/\(id)"
        endpoints = GoogleEndpoints(
            authorization: URL(string: "\(base)/authorize")!,
            token: URL(string: "\(base)/token")!,
            calendarAPI: URL(string: "\(base)/calendar/v3")!,
        )
        self.token = token
        self.events = events

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleStubURLProtocol.self]
        session = URLSession(configuration: configuration)
        GoogleStubURLProtocol.register(id: id, stub: self)
    }

    func release() {
        GoogleStubURLProtocol.unregister(id: id)
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var tokenRequests: [RecordedRequest] {
        requests.filter { $0.url.path.hasSuffix("/token") }
    }

    var eventRequests: [RecordedRequest] {
        requests.filter { $0.url.path.hasSuffix("/events") }
    }

    fileprivate func reply(to request: RecordedRequest) -> StubReply {
        let isToken = request.url.path.hasSuffix("/token")
        let isEvents = request.url.path.hasSuffix("/events")

        lock.lock()
        let index = recorded.filter { $0.url.path.hasSuffix(isToken ? "/token" : "/events") }.count
        recorded.append(request)
        lock.unlock()

        if isToken {
            return token(request, index)
        }
        if isEvents {
            return events(request, index)
        }
        return .failure(URLError(.unsupportedURL))
    }
}

final class GoogleStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stubs: [String: GoogleStub] = [:]

    fileprivate static func register(id: String, stub: GoogleStub) {
        lock.lock()
        stubs[id] = stub
        lock.unlock()
    }

    fileprivate static func unregister(id: String) {
        lock.lock()
        stubs.removeValue(forKey: id)
        lock.unlock()
    }

    private static func stub(for url: URL) -> GoogleStub? {
        // Path is "/<id>/…".
        let components = url.pathComponents
        guard components.count > 1 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return stubs[components[1]]
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let stub = Self.stub(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let recorded = RecordedRequest(
            url: url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request),
        )

        switch stub.reply(to: recorded) {
        case let .http(status, body):
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// `URLSession` hands a request body to a `URLProtocol` as a stream, not
    /// as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Clock

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

// MARK: - Harness

let testInstant = Date(timeIntervalSince1970: 1_800_000_000)

func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func at(minutes: Double, from base: Date = testInstant) -> Date {
    base.addingTimeInterval(minutes * 60)
}

/// One Google event as it appears in an `events.list` response.
func eventJSON(
    id: String,
    summary: String? = "Standup",
    start: Date?,
    end: Date?,
    status: String = "confirmed",
    attendees: [[String: String]]? = nil,
    allDayDate: String? = nil,
) -> [String: Any] {
    var event: [String: Any] = ["id": id, "status": status]
    if let summary {
        event["summary"] = summary
    }
    if let start, let end {
        event["start"] = ["dateTime": iso8601(start)]
        event["end"] = ["dateTime": iso8601(end)]
    } else if let allDayDate {
        event["start"] = ["date": allDayDate]
        event["end"] = ["date": allDayDate]
    }
    if let attendees {
        event["attendees"] = attendees
    }
    return event
}

func eventList(_ events: [[String: Any]]) -> StubReply {
    .json(200, ["items": events])
}

/// A `GoogleCalendarSource` wired to a stub and a throwaway Keychain service.
/// `storedRefreshToken` plants a refresh token there up front; pass `nil` to
/// leave the service empty.
struct SourceHarness {
    let stub: GoogleStub
    let service: String
    let clock: TestClock
    let source: GoogleCalendarSource

    init(
        client: GoogleOAuthClient = GoogleOAuthClient(clientID: "test-client.apps.googleusercontent.com"),
        storedRefreshToken: String? = "stored-refresh-token",
        redirectTimeout: Duration = .milliseconds(500),
        openBrowser: @escaping @Sendable (URL) async throws -> Void = { _ in },
        token: @escaping GoogleStub.Responder = GoogleStub.defaultToken,
        events: @escaping GoogleStub.Responder = GoogleStub.emptyEvents,
    ) throws {
        let stub = GoogleStub(token: token, events: events)
        let service = makeTestKeychainService()
        let clock = TestClock(testInstant)
        if let storedRefreshToken {
            try GoogleRefreshTokenStore.write(storedRefreshToken, service: service)
        }
        self.stub = stub
        self.service = service
        self.clock = clock
        source = GoogleCalendarSource(
            client: client,
            openBrowser: openBrowser,
            redirectTimeout: redirectTimeout,
            session: stub.session,
            endpoints: stub.endpoints,
            now: { clock.now },
            refreshTokenService: service,
        )
    }

    /// The stored refresh token, or `nil` when the throwaway service is empty.
    var storedRefreshToken: String? {
        try? GoogleRefreshTokenStore.read(service: service)
    }

    func cleanup() {
        stub.release()
        try? GoogleRefreshTokenStore.delete(service: service)
    }
}
