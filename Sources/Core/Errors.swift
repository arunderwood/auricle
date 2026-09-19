import Foundation

// Typed errors (AR-PAT-7): one `enum` per error domain, conforming to
// `Error`, with associated values carrying context. `NSError` bridging is
// translated to one of these immediately at the Apple-framework callback
// boundary that produced it, never propagated raw.
//
// The three domains here live in one file rather than three near-empty files:
// each domain's owning target (`Capture`, `Persist`, `Verify`) is still a
// placeholder with no real implementation to split alongside (AR-PAT-1 allows
// coupled secondary types sharing a file). `TranscriberError` and
// `SummarizerError` live in their own interface targets.

public enum CaptureError: Error, Sendable {
    /// `category` is a plain string, not `TCCCategory`: `Core` cannot depend
    /// on `Permissions` (module-boundary direction), so `TCCCategory` isn't
    /// visible here.
    case permissionDenied(category: String)
    case permissionRevokedMidstream
    case streamInterrupted(reason: String)
    case diskFull
}

/// `Persist`'s stage logic doesn't exist yet, so there's nothing concrete to
/// model failure around beyond a generic reason string.
public enum PersistError: Error, Sendable {
    case stageFailed(reason: String)
}

public enum VerifierError: Error, Sendable {
    case meetingNotFound
}
