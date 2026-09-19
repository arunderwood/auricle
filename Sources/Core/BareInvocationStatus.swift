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
/// in `BareInvocationResolver.resolve`'s priority order. The two `awaiting`
/// cases carry the id of the meeting the hint is about, so the command it
/// suggests acts on that meeting and not on whichever the resolver's
/// `current` and `last` keywords happen to name.
public enum BareInvocationStatus: Sendable, Equatable {
    case recording(id: String, elapsed: String)
    case awaitingAttribution(id: String)
    case awaitingVerification(id: String)
    case nothingInFlight

    /// The one line the bare command prints.
    public var message: String {
        switch self {
        case let .recording(id, elapsed):
            "Recording \(id) — \(elapsed)"
        case let .awaitingAttribution(id):
            "Last meeting awaiting attribution: auricle attribute \(id)"
        case let .awaitingVerification(id):
            "Last meeting awaiting your review: auricle keep \(id)"
        case .nothingInFlight:
            "Nothing in flight."
        }
    }
}

public enum BareInvocationResolver {
    /// Checks, in order, for a meeting `recording` → `awaiting_attribution`
    /// → `awaiting_verification`, falling back to `nothingInFlight` —
    /// Decision 1.5's bare-invocation priority, and Story 1.7's own
    /// boundary on it. Within a state the newest meeting wins, so a stranded
    /// older meeting never masks a newer one.
    public static func resolve(
        pending: [PendingMeetingSummary],
        now: Date = Date(),
    ) -> BareInvocationStatus {
        if let recording = newest(in: pending, state: "recording") {
            return .recording(
                id: recording.id,
                elapsed: elapsed(since: recording.referenceTimestamp, now: now),
            )
        }
        if let awaitingAttribution = newest(in: pending, state: "awaiting_attribution") {
            return .awaitingAttribution(id: awaitingAttribution.id)
        }
        if let awaitingVerification = newest(in: pending, state: "awaiting_verification") {
            return .awaitingVerification(id: awaitingVerification.id)
        }
        return .nothingInFlight
    }

    /// Newest by `referenceTimestamp`, ties by the larger id. ULIDs sort by
    /// creation time, so the larger id is the later-created meeting.
    private static func newest(in pending: [PendingMeetingSummary], state: String) -> PendingMeetingSummary? {
        pending.filter { $0.state == state }.max { isOlder($0, than: $1) }
    }

    /// Timestamps are compared as instants: one with fractional seconds and
    /// one without can differ by under a second in the wrong text order
    /// (`...00Z` sorts after `...00.398Z` but is the earlier instant). One that
    /// will not parse counts as older than every one that does, so the order
    /// stays a total order however the input is arranged.
    private static func isOlder(_ lhs: PendingMeetingSummary, than rhs: PendingMeetingSummary) -> Bool {
        let lhsDate = ISO8601UTC.date(from: lhs.referenceTimestamp) ?? .distantPast
        let rhsDate = ISO8601UTC.date(from: rhs.referenceTimestamp) ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return lhs.id < rhs.id
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
