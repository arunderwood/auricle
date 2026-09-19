import CalendarInterface

/// Why a Google call failed, in finer grain than `CalendarError` reports.
/// The distinctions stay inside this target and its logs; `calendarError` is
/// what crosses the `CalendarSource` boundary.
///
/// `authorizationFailed`'s `reason` is always a fixed string written in this
/// target, never text from a provider response, a token, a code or an address.
enum GoogleCalendarFailure: Error, Sendable, Equatable {
    /// No refresh token is stored: `authorize()` has never completed here.
    case notAuthorized
    /// Google no longer honors the credential (revoked or expired refresh
    /// token, or an access token it keeps rejecting).
    case authorizationExpired
    /// Authorization did not complete, or Google rejected the client's
    /// credentials when a token was requested.
    case authorizationFailed(reason: String)
    /// The service could not be reached, or answered with a server error.
    case unreachable
    /// The service throttled the request.
    case rateLimited
    /// The service answered, but not in a shape this source understands.
    case malformedResponse

    /// Everything about the credential maps to `authorizationExpired` (running
    /// `authorize()` again is the remedy); everything else means the answer
    /// could not be had right now, which is `unreachable`.
    var calendarError: CalendarError {
        switch self {
        case .notAuthorized, .authorizationExpired, .authorizationFailed:
            .authorizationExpired
        case .unreachable, .rateLimited, .malformedResponse:
            .unreachable
        }
    }

    /// A fixed string per case, safe to log verbatim: it never includes the
    /// `authorizationFailed` reason.
    var caseName: String {
        switch self {
        case .notAuthorized: "notAuthorized"
        case .authorizationExpired: "authorizationExpired"
        case .authorizationFailed: "authorizationFailed"
        case .unreachable: "unreachable"
        case .rateLimited: "rateLimited"
        case .malformedResponse: "malformedResponse"
        }
    }
}
