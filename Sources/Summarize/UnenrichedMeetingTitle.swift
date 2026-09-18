import Foundation

/// The frontmatter title for a meeting no calendar event enriched
/// (Decision 2.2's calendar-failed variant), e.g. `Meeting at
/// 2026-04-28T10:30 PDT`. The stamp is the capture start in the given time
/// zone: a title is read by the person who was in the room, so it is local
/// time, unlike every stored timestamp.
enum UnenrichedMeetingTitle {
    /// Numeric `DateComponents` rather than `DateFormatter`, so the digits
    /// cannot be reshaped by the process's `Locale` — only its time zone
    /// varies the result.
    static func title(captureStartedAt: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: captureStartedAt)
        let stamp = String(
            format: "%04d-%02d-%02dT%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
        )
        let zone = timeZone.abbreviation(for: captureStartedAt) ?? timeZone.identifier
        return "Meeting at \(stamp) \(zone)"
    }
}
