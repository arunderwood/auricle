import Foundation

/// Formats and parses the ISO8601 UTC timestamps `StateStore` persists.
/// `meetings.updated_at` is stamped by the `meetings_updated_at` SQL trigger
/// via `strftime('%Y-%m-%dT%H:%M:%fZ','now')`, which includes fractional
/// seconds; every timestamp this target writes itself
/// (`stage_events.occurred_at`, the `asOf` bound passed to
/// `fetchDueRetentionTimers`) does not. `date(from:)` accepts both.
///
/// `ISO8601DateFormatter` is a mutable, non-`Sendable` class (its `Sendable`
/// conformance is explicitly unavailable on this platform), so each call
/// below creates and configures its own local instance rather than sharing
/// one across actor-isolation boundaries.
enum ISO8601UTC {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) {
            return date
        }

        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: string)
    }
}
