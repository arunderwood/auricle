/// Failures a `CalendarSource` reports (AR-PAT-7). Story 3.11 consumes these to
/// decide how a meeting note degrades; none of them is fatal to the pipeline.
public enum CalendarError: Error, Sendable, Equatable {
    /// No stored credential: `authorize()` has never completed on this machine.
    case notAuthorized
    /// A credential exists but Google no longer honors it (revoked or expired
    /// refresh token, or a token the API keeps rejecting). Running
    /// `authorize()` again is the remedy.
    case authorizationExpired
    /// Authorization did not complete, or Google rejected the client's
    /// credentials when a token was requested. `reason` is a fixed,
    /// human-readable description and never carries a token, code or address.
    case authorizationFailed(reason: String)
    /// The service could not be reached, or answered with a server error.
    case unreachable
    /// The service throttled the request.
    case rateLimited
    /// The service answered, but not in a shape this source understands.
    case malformedResponse
}
