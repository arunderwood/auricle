import Foundation

/// Story 5.8's onboarding trigger: there is no public API to check or
/// request the "System Audio Recording" TCC grant (research.md), so the
/// only way to surface the OS's prompt is to actually run a tap briefly.
public enum SystemAudioPermissionProbe {
    /// Runs `source` for one second and discards every buffer — purely so
    /// macOS shows the System Audio Recording prompt the first time this
    /// runs, for onboarding to trigger ahead of the first real capture.
    public static func prompt(source: SystemAudioSource = ProcessTapSource()) async throws {
        try source.start()
        defer { source.stop() }
        try await Task.sleep(for: .seconds(1))
    }
}
