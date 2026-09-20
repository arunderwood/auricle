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

/// What `auricle`'s bare invocation (Decision 1.5) can print, one case per
/// pending state it reports, in `BareInvocationResolver.resolve`'s priority
/// order. Every case but `recording` and `nothingInFlight` carries the id of
/// the meeting the line is about, so a command it suggests acts on that meeting
/// and not on whichever the resolver's `current` and `last` keywords happen to
/// name.
public enum BareInvocationStatus: Sendable, Equatable {
    case recording(id: String, elapsed: String)
    case awaitingAttribution(id: String)
    case awaitingVerification(id: String)
    case captureFailed(id: String)
    case transcriptionFailed(id: String)
    case summarizationFailed(id: String)
    case persistFailed(id: String)
    case publishedPartial(id: String)
    case captured(id: String)
    case transcribing(id: String)
    case reviewingDiarization(id: String)
    case attributing(id: String)
    case summarizing(id: String)
    case persisting(id: String)
    case published(id: String)
    case nothingInFlight

    /// The one line the bare command prints. A recovery command appears only
    /// where architecture.md documents one for the state (Decisions 1.5, 4.1):
    /// `run <id>` resumes a transient failure, `run <id> --force` overrides a
    /// permanent one, and `run <id> --reattribute` is the way out of
    /// `published_partial`.
    public var message: String {
        switch self {
        case let .recording(id, elapsed):
            "Recording \(id) — \(elapsed)"
        case let .awaitingAttribution(id):
            "Last meeting awaiting attribution: auricle attribute \(id)"
        case let .awaitingVerification(id):
            "Last meeting awaiting your review: auricle keep \(id)"
        case let .captureFailed(id):
            "Capture failed for \(id) — after investigating, retry: auricle run \(id) --force"
        case let .transcriptionFailed(id):
            "Transcription failed for \(id) — after investigating, retry: auricle run \(id) --force"
        case let .summarizationFailed(id):
            "Summarization failed for \(id) — resume: auricle run \(id)"
        case let .persistFailed(id):
            "Writing the vault note failed for \(id) — resume: auricle run \(id)"
        case let .publishedPartial(id):
            "Published \(id) with placeholder speaker names and no summary — fix it in Obsidian, or: auricle run \(id) --reattribute"
        case let .captured(id):
            "Captured \(id) — transcription not started"
        case let .transcribing(id):
            "Transcribing \(id)"
        case let .reviewingDiarization(id):
            "Reviewing speaker labels for \(id)"
        case let .attributing(id):
            "Attributing \(id) — waiting on you"
        case let .summarizing(id):
            "Summarizing \(id)"
        case let .persisting(id):
            "Writing the vault note for \(id)"
        case let .published(id):
            "Published \(id) — review notification pending"
        case .nothingInFlight:
            "Nothing in flight."
        }
    }
}

public enum BareInvocationResolver {
    /// The states the bare command reports after `recording`, most important
    /// first, each with the case that carries its meeting's id. Decision 1.5
    /// (and Story 1.7's boundary on it) orders only `recording`,
    /// `awaiting_attribution` and `awaiting_verification`. Every other state
    /// ranks behind those three and never displaces them: a meeting that needs
    /// an action (a failure, a partial publish) before one that is moving on
    /// its own, and each group in pipeline order. `silent` is a benign halt,
    /// and the three other states left out are terminal
    /// (`StateStore.fetchPending` never returns them), so none of the four is
    /// in flight.
    private static let reported: [(state: PipelineState, status: @Sendable (String) -> BareInvocationStatus)] = [
        (.awaitingAttribution, BareInvocationStatus.awaitingAttribution),
        (.awaitingVerification, BareInvocationStatus.awaitingVerification),
        (.captureFailed, BareInvocationStatus.captureFailed),
        (.transcriptionFailed, BareInvocationStatus.transcriptionFailed),
        (.summarizationFailed, BareInvocationStatus.summarizationFailed),
        (.persistFailed, BareInvocationStatus.persistFailed),
        (.publishedPartial, BareInvocationStatus.publishedPartial),
        (.captured, BareInvocationStatus.captured),
        (.transcribing, BareInvocationStatus.transcribing),
        (.reviewingDiarization, BareInvocationStatus.reviewingDiarization),
        (.attributing, BareInvocationStatus.attributing),
        (.summarizing, BareInvocationStatus.summarizing),
        (.persisting, BareInvocationStatus.persisting),
        (.published, BareInvocationStatus.published),
    ]

    /// Reports `recording` first, then the first state in `reported` that has
    /// a pending meeting, and `nothingInFlight` when none does. Within a state
    /// the newest meeting wins, so a stranded older meeting never masks a newer
    /// one. A state string `PipelineState` does not know is never matched.
    public static func resolve(
        pending: [PendingMeetingSummary],
        now: Date = Date(),
    ) -> BareInvocationStatus {
        if let recording = newest(in: pending, state: .recording) {
            return .recording(
                id: recording.id,
                elapsed: elapsed(since: recording.referenceTimestamp, now: now),
            )
        }
        for (state, status) in reported {
            if let meeting = newest(in: pending, state: state) {
                return status(meeting.id)
            }
        }
        return .nothingInFlight
    }

    /// Newest by `referenceTimestamp`, ties by the larger id. ULIDs sort by
    /// creation time, so the larger id is the later-created meeting.
    private static func newest(in pending: [PendingMeetingSummary], state: PipelineState) -> PendingMeetingSummary? {
        pending.filter { $0.state == state.rawValue }.max { isOlder($0, than: $1) }
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
