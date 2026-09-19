/// The two ways a calendar source reports it cannot answer. Neither carries a
/// payload, so nothing a provider says can reach a log line or a stored error.
public enum CalendarError: Error, Sendable, Equatable {
    /// The stored credential is missing, revoked or could not be refreshed.
    case authorizationExpired
    /// The provider could not be reached.
    case unreachable
}
