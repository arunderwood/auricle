import Foundation

/// The four permission surfaces `PermissionChecker` covers (Decision 4.4).
/// `.systemAudioCapture` has no public read/request API on macOS — it is
/// tracked here anyway so `auricle doctor` and Capture's own probes can
/// name it alongside the other three in one enum. `.calendarOAuth` is not
/// TCC at all; its token lives in `GoogleCalendarSource`, which
/// `Permissions` does not depend on, so it is status-only here too.
public enum TCCCategory: Sendable, Hashable, CaseIterable {
    case systemAudioCapture
    case microphone
    case notifications
    case calendarOAuth
}

/// `.unknown` is distinct from `.notDetermined`: `.notDetermined` means macOS
/// can answer but hasn't been asked yet; `.unknown` means macOS has no API to
/// answer at all (`.systemAudioCapture`) or the answer lives outside TCC
/// (`.calendarOAuth`).
public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    case unknown
}
