import Foundation

/// One pending meeting's state plus the single timestamp
/// `BareInvocationResolver` needs. Deliberately not `State.Meeting`: `Core`
/// can't depend on `State` (module boundaries are build-time enforced), so
/// the CLI's `BareInvocation` verb maps each fetched `Meeting` into this
/// shape at the call site.
public struct PendingMeetingSummary: Sendable, Equatable {
    public let id: String
    public let state: String
    /// ISO8601 UTC timestamp elapsed-duration is measured from, when
    /// `state == "recording"`: `capture_started_at`, falling back to
    /// `created_at` if capture hasn't been marked started yet.
    public let referenceTimestamp: String

    public init(id: String, state: String, referenceTimestamp: String) {
        self.id = id
        self.state = state
        self.referenceTimestamp = referenceTimestamp
    }
}

/// The four outcomes `auricle`'s bare invocation (Decision 1.5) can print,
/// in `BareInvocationResolver.resolve`'s priority order.
public enum BareInvocationStatus: Sendable, Equatable {
    case recording(id: String, elapsed: String)
    case awaitingAttribution
    case awaitingVerification
    case nothingInFlight
}

public enum BareInvocationResolver {
    /// Checks, in order, for a meeting `recording` → `awaiting_attribution`
    /// → `awaiting_verification`, falling back to `nothingInFlight` —
    /// Decision 1.5's bare-invocation priority, and Story 1.7's own
    /// boundary on it.
    public static func resolve(
        pending: [PendingMeetingSummary],
        now: Date = Date(),
    ) -> BareInvocationStatus {
        if let recording = pending.first(where: { $0.state == "recording" }) {
            return .recording(
                id: recording.id,
                elapsed: elapsed(since: recording.referenceTimestamp, now: now),
            )
        }
        if pending.contains(where: { $0.state == "awaiting_attribution" }) {
            return .awaitingAttribution
        }
        if pending.contains(where: { $0.state == "awaiting_verification" }) {
            return .awaitingVerification
        }
        return .nothingInFlight
    }

    /// "unknown duration" only if `referenceTimestamp` fails to parse as
    /// ISO8601 at all — shouldn't happen against a real `StateStore` row,
    /// since every writer of these columns goes through
    /// `ISO8601UTC.string(from:)`.
    public static func elapsed(since referenceTimestamp: String, now: Date) -> String {
        guard let start = ISO8601UTC.date(from: referenceTimestamp) else { return "unknown duration" }
        let totalSeconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(seconds)s"
        }
        return "\(minutes)m \(seconds)s"
    }
}
