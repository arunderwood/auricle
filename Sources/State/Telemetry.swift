import GRDB

/// The wedge-validation measurement window `audioRetentionStatusAtSnapshot`
/// is backfilled at, in days after capture (architecture.md:1251). Kept as a
/// named constant rather than baked into the column/property name, so a
/// future change to the window is a one-line edit here instead of another
/// migration to rename the column again. Independent of the user-configurable
/// per-meeting retention grace window (FR50), which is a different setting
/// entirely.
public enum TelemetrySnapshotPolicy: Sendable {
    public static let audioRetentionSnapshotDays = 30
}

/// GRDB record for `telemetry` (architecture.md Decision 2.1) — the
/// per-meeting telemetry rollup, one row populated incrementally via UPSERT
/// as different stages contribute different columns. Every wedge-validation
/// and trust-calibration counter column from migration #1 is represented
/// here, including the `transcription_*` columns that are declared but have
/// no MVP writer yet (Decision 5.5 Phase 3) — their existence is the
/// schema-stable contract (Amelia's Story 1 blocker).
///
/// This type owns only the record shape. The partitioned UPSERT write API
/// that enforces the write-authority matrix (architecture.md:800-823) is
/// `TelemetryRecorder` in the `Telemetry` target (Story 1.6), not this type.
public struct Telemetry: Codable, Equatable, Sendable {
    public var meetingID: String
    public var timeToAttributionReadySeconds: Int?
    public var timeToVaultNoteSeconds: Int?
    public var transcriptionWEREstimate: Double?
    public var quoteValidationDropCount: Int?
    public var attributionCompletionPath: String?
    public var summarizationPath: String?
    public var summarizationModel: String?
    public var summarizationEffortBudget: String?
    public var costUSD: Double?
    public var diarizationSuggestionsCount: Int?
    public var diarizationSuggestionsAppliedCount: Int?
    public var diarizationSuggestionsRejectedCount: Int?
    public var diarizationReviewCostUSD: Double?
    public var diarizationReviewModel: String?
    public var transcriptionSuggestionsCount: Int?
    public var transcriptionSuggestionsAppliedCount: Int?
    public var transcriptionSuggestionsRejectedCount: Int?
    public var transcriptionReviewCostUSD: Double?
    public var transcriptionReviewModel: String?
    public var audioRetentionStatusAtSnapshot: String?

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case timeToAttributionReadySeconds = "time_to_attribution_ready_seconds"
        case timeToVaultNoteSeconds = "time_to_vault_note_seconds"
        case transcriptionWEREstimate = "transcription_wer_estimate"
        case quoteValidationDropCount = "quote_validation_drop_count"
        case attributionCompletionPath = "attribution_completion_path"
        case summarizationPath = "summarization_path"
        case summarizationModel = "summarization_model"
        case summarizationEffortBudget = "summarization_effort_budget"
        case costUSD = "cost_usd"
        case diarizationSuggestionsCount = "diarization_suggestions_count"
        case diarizationSuggestionsAppliedCount = "diarization_suggestions_applied_count"
        case diarizationSuggestionsRejectedCount = "diarization_suggestions_rejected_count"
        case diarizationReviewCostUSD = "diarization_review_cost_usd"
        case diarizationReviewModel = "diarization_review_model"
        case transcriptionSuggestionsCount = "transcription_suggestions_count"
        case transcriptionSuggestionsAppliedCount = "transcription_suggestions_applied_count"
        case transcriptionSuggestionsRejectedCount = "transcription_suggestions_rejected_count"
        case transcriptionReviewCostUSD = "transcription_review_cost_usd"
        case transcriptionReviewModel = "transcription_review_model"
        case audioRetentionStatusAtSnapshot = "audio_retention_status_at_snapshot"
    }

    public init(
        meetingID: String,
        timeToAttributionReadySeconds: Int? = nil,
        timeToVaultNoteSeconds: Int? = nil,
        transcriptionWEREstimate: Double? = nil,
        quoteValidationDropCount: Int? = nil,
        attributionCompletionPath: String? = nil,
        summarizationPath: String? = nil,
        summarizationModel: String? = nil,
        summarizationEffortBudget: String? = nil,
        costUSD: Double? = nil,
        diarizationSuggestionsCount: Int? = nil,
        diarizationSuggestionsAppliedCount: Int? = nil,
        diarizationSuggestionsRejectedCount: Int? = nil,
        diarizationReviewCostUSD: Double? = nil,
        diarizationReviewModel: String? = nil,
        transcriptionSuggestionsCount: Int? = nil,
        transcriptionSuggestionsAppliedCount: Int? = nil,
        transcriptionSuggestionsRejectedCount: Int? = nil,
        transcriptionReviewCostUSD: Double? = nil,
        transcriptionReviewModel: String? = nil,
        audioRetentionStatusAtSnapshot: String? = nil,
    ) {
        self.meetingID = meetingID
        self.timeToAttributionReadySeconds = timeToAttributionReadySeconds
        self.timeToVaultNoteSeconds = timeToVaultNoteSeconds
        self.transcriptionWEREstimate = transcriptionWEREstimate
        self.quoteValidationDropCount = quoteValidationDropCount
        self.attributionCompletionPath = attributionCompletionPath
        self.summarizationPath = summarizationPath
        self.summarizationModel = summarizationModel
        self.summarizationEffortBudget = summarizationEffortBudget
        self.costUSD = costUSD
        self.diarizationSuggestionsCount = diarizationSuggestionsCount
        self.diarizationSuggestionsAppliedCount = diarizationSuggestionsAppliedCount
        self.diarizationSuggestionsRejectedCount = diarizationSuggestionsRejectedCount
        self.diarizationReviewCostUSD = diarizationReviewCostUSD
        self.diarizationReviewModel = diarizationReviewModel
        self.transcriptionSuggestionsCount = transcriptionSuggestionsCount
        self.transcriptionSuggestionsAppliedCount = transcriptionSuggestionsAppliedCount
        self.transcriptionSuggestionsRejectedCount = transcriptionSuggestionsRejectedCount
        self.transcriptionReviewCostUSD = transcriptionReviewCostUSD
        self.transcriptionReviewModel = transcriptionReviewModel
        self.audioRetentionStatusAtSnapshot = audioRetentionStatusAtSnapshot
    }
}

extension Telemetry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "telemetry"
}
