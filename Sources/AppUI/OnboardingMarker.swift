import Core
import Foundation

/// The first-run gate: onboarding runs exactly when this marker is absent.
/// Mirrors `DatabasePoolFactory`'s own production-path pattern — a fixed
/// subpath under an injected Application Support root — so a test never
/// touches the real one and `AuricleApp` supplies the real root the same way
/// it supplies the real database path.
public enum OnboardingMarker {
    static let subpath = "com.auricle.app/onboarding-completed"

    public static func exists(applicationSupportDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(in: applicationSupportDirectory).path)
    }

    /// Creates the containing directory if it doesn't exist yet, then writes
    /// an empty marker file through `AtomicWriter` — the sole file-write
    /// primitive (AR-PAT-4) — rather than a direct filesystem call.
    /// Idempotent: writing over an existing marker is not an error.
    public static func write(applicationSupportDirectory: URL) throws {
        let url = markerURL(in: applicationSupportDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWriter.write(Data(), to: url)
    }

    private static func markerURL(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent(subpath)
    }
}
