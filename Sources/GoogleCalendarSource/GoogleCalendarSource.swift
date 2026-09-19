import CalendarInterface
import Core
import Foundation

/// `CalendarSource` backed by the user's primary Google calendar over the
/// read-only Calendar API v3 (FR51, FR52, NFR-I5).
///
/// The refresh token lives only in Keychain and is read at the moment a
/// refresh needs it. The access token lives only in this actor's memory. A
/// rejected access token (401) gets one refresh and one re-send of the
/// request; nothing else is retried. The calendar is off the pipeline's hot
/// path, and a failure already has a designed outcome (Story 3.11).
///
/// Internally a failure is a `GoogleCalendarFailure`; the public methods
/// report it as the `CalendarError` it maps to. `fetchActiveEvent` and
/// `upcomingEvents` each finish within `lookupTimeout` or throw
/// `CalendarError.unreachable`: the summarize stage sets no deadline of its
/// own, so a lookup that never returned would hang the meeting.
public actor GoogleCalendarSource: CalendarSource {
    private struct CachedAccessToken {
        let value: String
        let expiresAt: Date
    }

    /// An access token this close to expiry is refreshed before use, so a
    /// request never leaves with a token that expires in flight.
    private static let expiryMargin: TimeInterval = 60

    private static let listPageSize = 250

    /// Limited to what `CalendarEvent` carries, plus `status`, which the
    /// matcher needs to skip cancelled events. Times ask for `dateTime` only;
    /// an all-day event's bare `date` is never used.
    private static let fieldsMask = "items(id,status,summary,start(dateTime),end(dateTime),attendees(email,displayName,self))"

    /// Google's `403` reasons that mean "slow down" rather than "not allowed".
    private static let rateLimitReasons: Set<String> = [
        "ratelimitexceeded",
        "userratelimitexceeded",
        "dailylimitexceeded",
        "quotaexceeded",
        "calendarusagelimitsexceeded",
    ]

    private let flow: GoogleOAuthFlow
    private let session: URLSession
    private let calendarAPI: URL
    private let lookupTimeout: Duration
    private let requestTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let refreshTokenService: String
    private let log = Log(category: "google-calendar")

    private var accessToken: CachedAccessToken?

    /// `openBrowser` is handed the authorization URL and should show it to the
    /// user; it is injected so this target never touches AppKit. Nothing here
    /// reads configuration: the client registration arrives through `client`.
    ///
    /// `redirectTimeout` bounds the user-paced `authorize()`; `lookupTimeout`
    /// bounds each whole `fetchActiveEvent` or `upcomingEvents` call.
    public init(
        client: GoogleOAuthClient,
        openBrowser: @escaping @Sendable (URL) async throws -> Void,
        redirectTimeout: Duration = .seconds(300),
        lookupTimeout: Duration = .seconds(15),
        session: URLSession = GoogleCalendarSource.makeDefaultSession(),
        endpoints: GoogleEndpoints = .production,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.init(
            flow: GoogleOAuthFlow(
                client: client,
                endpoints: endpoints,
                session: session,
                openBrowser: openBrowser,
                redirectTimeout: redirectTimeout,
            ),
            lookupTimeout: lookupTimeout,
            now: now,
            refreshTokenService: GoogleRefreshTokenStore.productionService,
        )
    }

    /// Lets tests keep the refresh token under a throwaway Keychain service so
    /// they never touch the maintainer's real item, and hold the flow they
    /// hand in.
    init(
        flow: GoogleOAuthFlow,
        lookupTimeout: Duration,
        now: @escaping @Sendable () -> Date,
        refreshTokenService: String,
    ) {
        self.flow = flow
        session = flow.session
        calendarAPI = flow.endpoints.calendarAPI
        requestTimeout = flow.requestTimeout
        self.lookupTimeout = lookupTimeout
        self.now = now
        self.refreshTokenService = refreshTokenService
    }

    /// Ephemeral, TLS 1.2 minimum (NFR-S5); there is no weaker fallback.
    public static func makeDefaultSession() -> URLSession {
        GoogleTransport.makeDefaultSession()
    }

    // MARK: - CalendarSource

    public func authorize() async throws {
        try await reportingCalendarErrors {
            let grant = try await flow.authorize()

            do {
                try GoogleRefreshTokenStore.write(grant.refreshToken, service: refreshTokenService)
            } catch {
                throw GoogleCalendarFailure.authorizationFailed(reason: "the refresh token could not be stored in Keychain")
            }
            cache(grant.access)
            log.info("google calendar authorized")
        }
    }

    public func fetchActiveEvent(at instant: Date) async throws -> CalendarEvent? {
        try await reportingCalendarErrors {
            // Calendar's `timeMin` bounds an event's end exclusively and `timeMax`
            // bounds its start exclusively; a second of slack each way lets an
            // event that ends or starts exactly at `instant` come back so the
            // matcher's inclusive comparison can accept it.
            let events = try await boundedEvents(timeMin: instant.addingTimeInterval(-1), timeMax: instant.addingTimeInterval(1))
            return EventMatcher.activeEvent(at: instant, among: events)
        }
    }

    public func upcomingEvents(in window: TimeInterval) async throws -> [CalendarEvent] {
        guard window >= 0 else { return [] }
        return try await reportingCalendarErrors {
            let start = now()
            let events = try await boundedEvents(timeMin: start, timeMax: start.addingTimeInterval(window + 1))
            return EventMatcher.upcomingEvents(from: start, window: window, among: events)
        }
    }

    /// The only place a `GoogleCalendarFailure` becomes a `CalendarError`.
    /// Cancellation (`CancellationError`, `URLError(.cancelled)`) is not a
    /// failure of either kind and passes through untouched.
    private func reportingCalendarErrors<Result>(_ operation: () async throws -> Result) async throws -> Result {
        do {
            return try await operation()
        } catch let failure as GoogleCalendarFailure {
            var fields: [String: LogSensitivity] = ["failure": .publicSafe(failure.caseName)]
            if let reason = failure.logReason {
                fields["reason"] = .publicSafe(reason)
            }
            log.warn("google calendar call failed", fields)
            throw failure.calendarError
        }
    }

    // MARK: - Calendar API

    /// Races the whole list call (token refresh, request and the one 401
    /// retry) against `lookupTimeout`. The work runs in a child task and the
    /// actor stays free while it waits. When the timer wins the work is
    /// cancelled and the call reports `unreachable`; if the caller itself was
    /// cancelled that is reported as cancellation instead.
    private func boundedEvents(timeMin: Date, timeMax: Date) async throws -> [GoogleEvent] {
        let timeout = lookupTimeout
        return try await withThrowingTaskGroup(of: [GoogleEvent]?.self) { group in
            group.addTask { try await self.listEvents(timeMin: timeMin, timeMax: timeMax) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }

            guard let events = try await group.next() ?? nil else {
                try Task.checkCancellation()
                log.warn("google calendar lookup timed out")
                throw GoogleCalendarFailure.unreachable
            }
            return events
        }
    }

    func listEvents(timeMin: Date, timeMax: Date) async throws -> [GoogleEvent] {
        let url = eventsURL(timeMin: timeMin, timeMax: timeMax)
        var token = try await validAccessToken()

        for attempt in 1 ... 2 {
            let response = try await GoogleTransport.perform(authorizedRequest(url: url, token: token), using: session, timeout: requestTimeout)
            log.info("google calendar request answered", ["statusCode": .publicSafe(response.status)])

            if response.status == 401 {
                accessToken = nil
                guard attempt == 1 else { throw GoogleCalendarFailure.authorizationExpired }
                token = try await refreshAccessToken()
                continue
            }
            return try events(fromStatus: response.status, body: response.body)
        }
        throw GoogleCalendarFailure.authorizationExpired
    }

    private func events(fromStatus status: Int, body: Data) throws -> [GoogleEvent] {
        switch status {
        case 200 ..< 300:
            guard let list = try? JSONDecoder().decode(GoogleEventList.self, from: body) else {
                throw GoogleCalendarFailure.malformedResponse
            }
            log.info("google calendar events decoded", ["eventCount": .publicSafe(list.events.count)])
            return list.events
        case 403:
            throw Self.isRateLimit(body) ? GoogleCalendarFailure.rateLimited : GoogleCalendarFailure.authorizationExpired
        case 429:
            throw GoogleCalendarFailure.rateLimited
        case 500 ... 599:
            throw GoogleCalendarFailure.unreachable
        default:
            // A 4xx this source doesn't model means the request it built was
            // not one Google understood, which is a shape mismatch, not an
            // authorization problem.
            throw GoogleCalendarFailure.malformedResponse
        }
    }

    private func eventsURL(timeMin: Date, timeMax: Date) -> URL {
        let base = calendarAPI.appendingPathComponent("calendars/primary/events")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: String(Self.listPageSize)),
            URLQueryItem(name: "timeMin", value: ISO8601UTC.string(from: timeMin)),
            URLQueryItem(name: "timeMax", value: ISO8601UTC.string(from: timeMax)),
            URLQueryItem(name: "fields", value: Self.fieldsMask),
        ]
        return components.url!
    }

    private func authorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// A `403` is a throttle only when Google's error body says so; any other
    /// `403` (insufficient scope, revoked access) is an authorization problem.
    private static func isRateLimit(_ body: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(GoogleErrorEnvelope.self, from: body) else { return false }
        return envelope.error.errors.contains { rateLimitReasons.contains($0.reason.lowercased()) }
    }

    // MARK: - Access token

    private func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expiresAt.timeIntervalSince(now()) > Self.expiryMargin {
            return accessToken.value
        }
        return try await refreshAccessToken()
    }

    /// Reads the refresh token, uses it once, and lets it go out of scope.
    private func refreshAccessToken() async throws -> String {
        accessToken = nil
        let refreshToken: String
        do {
            refreshToken = try GoogleRefreshTokenStore.read(service: refreshTokenService)
        } catch GoogleRefreshTokenStoreError.notFound {
            throw GoogleCalendarFailure.notAuthorized
        } catch {
            throw GoogleCalendarFailure.authorizationFailed(reason: "the refresh token could not be read from Keychain")
        }

        let grant = try await flow.refresh(refreshToken: refreshToken)
        cache(grant)
        return grant.accessToken
    }

    private func cache(_ grant: AccessTokenGrant) {
        accessToken = CachedAccessToken(value: grant.accessToken, expiresAt: now().addingTimeInterval(grant.expiresIn))
    }
}

/// `{"error": {"errors": [{"reason": "rateLimitExceeded"}]}}`
private struct GoogleErrorEnvelope: Decodable {
    let error: GoogleErrorDetail
}

private struct GoogleErrorDetail: Decodable {
    let errors: [GoogleErrorReason]

    private enum CodingKeys: String, CodingKey {
        case errors
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errors = try container.decodeIfPresent([GoogleErrorReason].self, forKey: .errors) ?? []
    }
}

private struct GoogleErrorReason: Decodable {
    let reason: String
}
