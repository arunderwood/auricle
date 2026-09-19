import CalendarInterface
import Foundation

/// The three Google URLs the source talks to. Injectable so tests can point
/// them at a stub; every one must be HTTPS (NFR-S5), and there is no
/// fallback to anything weaker.
public struct GoogleEndpoints: Sendable {
    /// Opened in the user's browser, never fetched by `URLSession`.
    public let authorization: URL
    public let token: URL
    /// The Calendar API v3 root; requests append `calendars/primary/events`.
    public let calendarAPI: URL

    public static let production = GoogleEndpoints(
        authorization: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        token: URL(string: "https://oauth2.googleapis.com/token")!,
        calendarAPI: URL(string: "https://www.googleapis.com/calendar/v3")!,
    )

    public init(authorization: URL, token: URL, calendarAPI: URL) {
        for url in [authorization, token, calendarAPI] {
            precondition(url.scheme?.lowercased() == "https", "Google endpoints must use https")
        }
        self.authorization = authorization
        self.token = token
        self.calendarAPI = calendarAPI
    }
}

/// Shared HTTP plumbing for the OAuth and Calendar calls: an ephemeral,
/// TLS 1.2+ session and one place where a transport failure becomes a typed
/// `CalendarError`.
enum GoogleTransport {
    /// `.ephemeral` so nothing (cookies, cached responses, credentials) is
    /// left on disk, consistent with keeping tokens out of persistent storage
    /// other than Keychain (NFR-S1).
    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration)
    }

    /// One attempt, no retry. Cancellation is never turned into a
    /// `CalendarError`: it propagates so the caller's task ends as cancelled.
    static func perform(_ request: URLRequest, using session: URLSession) async throws -> (status: Int, body: Data) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw urlError
        } catch {
            throw CalendarError.unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw CalendarError.malformedResponse
        }
        return (http.statusCode, data)
    }
}
