import Core
import Foundation

/// Raised by the opener a headless worker hands the source.
struct HeadlessAuthorizationUnavailable: Error {}

extension GoogleCalendarSource {
    /// Opens no browser and throws instead. A worker process has no user to
    /// finish a sign-in, so `authorize()` must fail at once rather than wait out
    /// its five-minute redirect timeout. The summarize stage never calls it; a
    /// caller that did would learn the source is unauthorized.
    static let headlessBrowserOpener: @Sendable (URL) async throws -> Void = { _ in
        throw HeadlessAuthorizationUnavailable()
    }

    /// The source a subprocess worker uses, or `nil` when the config names no
    /// client id: without one there is nothing to authenticate as, and the
    /// summarize stage already handles a missing source. Signing in happens
    /// elsewhere; this source only reuses the refresh token that left in
    /// Keychain.
    public static func headless(_ configuration: Config.GoogleCalendar) -> GoogleCalendarSource? {
        guard let clientID = configuration.clientID else { return nil }
        return GoogleCalendarSource(
            client: GoogleOAuthClient(clientID: clientID, clientSecret: configuration.clientSecret),
            openBrowser: headlessBrowserOpener,
        )
    }
}
