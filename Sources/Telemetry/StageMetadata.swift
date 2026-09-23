/// The per-stage `completed`-event payload types (architecture.md Decision
/// 4.5). A stage encodes its own `*Meta` struct directly and hands the string
/// to `StageRunner`'s `StageOutcome`, so the `metadata_json` a row stores is
/// the flat payload. This enum's wrapped encoding is never what a stage
/// writes. `verify`/`discard` have no case here; their events carry no typed
/// metadata.
///
/// `Codable` conformance is hand-written rather than compiler-synthesized:
/// Swift does not synthesize `Codable` for an enum with associated values, and
/// a `CaptureMeta` with no fields set and `attribute`'s placeholder payload
/// are both content-identical empty objects (`{}`) — indistinguishable by
/// content alone, so the case must be recovered from which keyed-container
/// key is present, not from the payload's shape.
public enum StageMetadata: Equatable, Sendable {
    case capture(CaptureMeta)
    case transcribe(TranscribeMeta)
    case reviewDiarization(ReviewDiarizationMeta)
    case attribute(AttributeMeta)
    case summarize(SummarizeMeta)
    case persist(PersistMeta)
    case notify(NotifyMeta)
}

extension StageMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case capture
        case transcribe
        case reviewDiarization = "review_diarization"
        case attribute
        case summarize
        case persist
        case notify
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription:
                "Expected exactly one recognized StageMetadata case key, found \(container.allKeys.count)",
            ))
        }
        if let meta = try container.decodeIfPresent(CaptureMeta.self, forKey: .capture) {
            self = .capture(meta)
        } else if let meta = try container.decodeIfPresent(TranscribeMeta.self, forKey: .transcribe) {
            self = .transcribe(meta)
        } else if let meta = try container.decodeIfPresent(ReviewDiarizationMeta.self, forKey: .reviewDiarization) {
            self = .reviewDiarization(meta)
        } else if let meta = try container.decodeIfPresent(AttributeMeta.self, forKey: .attribute) {
            self = .attribute(meta)
        } else if let meta = try container.decodeIfPresent(SummarizeMeta.self, forKey: .summarize) {
            self = .summarize(meta)
        } else if let meta = try container.decodeIfPresent(PersistMeta.self, forKey: .persist) {
            self = .persist(meta)
        } else if let meta = try container.decodeIfPresent(NotifyMeta.self, forKey: .notify) {
            self = .notify(meta)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "No recognized StageMetadata case key present",
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .capture(meta): try container.encode(meta, forKey: .capture)
        case let .transcribe(meta): try container.encode(meta, forKey: .transcribe)
        case let .reviewDiarization(meta): try container.encode(meta, forKey: .reviewDiarization)
        case let .attribute(meta): try container.encode(meta, forKey: .attribute)
        case let .summarize(meta): try container.encode(meta, forKey: .summarize)
        case let .persist(meta): try container.encode(meta, forKey: .persist)
        case let .notify(meta): try container.encode(meta, forKey: .notify)
        }
    }
}

/// A live capture's `completed`/`failed`/`retried` payload. Every field is
/// optional and omitted when absent, so a row carries only what its event
/// knows and a later capture field is an additive change: `mic_included`,
/// `exact_zero_seconds` and `tap_rebuilds` describe a finished capture;
/// `reason` says why an interrupted capture was recovered; `error_class` is
/// why a capture failed, the same key `StageRunner` writes for other stages;
/// `source` names which input (`microphone`, `system_audio`) a fault came from.
/// The three `system_audio_*` fields are present only on a capture that lost
/// system audio and carried on with the microphone: the most recent loss and
/// restore, as ISO 8601 UTC, and how many times it was lost. A `retried`
/// event also carries `attempt_number`, `previous_error_class` and
/// `backoff_ms`, the shape every stage's `retried` metadata takes.
public struct CaptureMeta: Codable, Equatable, Sendable {
    public var micIncluded: Bool?
    public var exactZeroSeconds: Double?
    public var tapRebuilds: Int?
    public var reason: String?
    public var errorClass: String?
    public var source: String?
    public var attemptNumber: Int?
    public var previousErrorClass: String?
    public var backoffMS: Int?
    public var systemAudioLostAt: String?
    public var systemAudioRestoredAt: String?
    public var systemAudioLossCount: Int?

    enum CodingKeys: String, CodingKey {
        case micIncluded = "mic_included"
        case exactZeroSeconds = "exact_zero_seconds"
        case tapRebuilds = "tap_rebuilds"
        case reason
        case errorClass = "error_class"
        case source
        case attemptNumber = "attempt_number"
        case previousErrorClass = "previous_error_class"
        case backoffMS = "backoff_ms"
        case systemAudioLostAt = "system_audio_lost_at"
        case systemAudioRestoredAt = "system_audio_restored_at"
        case systemAudioLossCount = "system_audio_loss_count"
    }

    public init(
        micIncluded: Bool? = nil,
        exactZeroSeconds: Double? = nil,
        tapRebuilds: Int? = nil,
        reason: String? = nil,
        errorClass: String? = nil,
        source: String? = nil,
        attemptNumber: Int? = nil,
        previousErrorClass: String? = nil,
        backoffMS: Int? = nil,
        systemAudioLostAt: String? = nil,
        systemAudioRestoredAt: String? = nil,
        systemAudioLossCount: Int? = nil,
    ) {
        self.micIncluded = micIncluded
        self.exactZeroSeconds = exactZeroSeconds
        self.tapRebuilds = tapRebuilds
        self.reason = reason
        self.errorClass = errorClass
        self.source = source
        self.attemptNumber = attemptNumber
        self.previousErrorClass = previousErrorClass
        self.backoffMS = backoffMS
        self.systemAudioLostAt = systemAudioLostAt
        self.systemAudioRestoredAt = systemAudioRestoredAt
        self.systemAudioLossCount = systemAudioLossCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        micIncluded = try container.decodeIfPresent(Bool.self, forKey: .micIncluded)
        exactZeroSeconds = try container.decodeIfPresent(Double.self, forKey: .exactZeroSeconds)
        tapRebuilds = try container.decodeIfPresent(Int.self, forKey: .tapRebuilds)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        errorClass = try container.decodeIfPresent(String.self, forKey: .errorClass)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        attemptNumber = try container.decodeIfPresent(Int.self, forKey: .attemptNumber)
        previousErrorClass = try container.decodeIfPresent(String.self, forKey: .previousErrorClass)
        backoffMS = try container.decodeIfPresent(Int.self, forKey: .backoffMS)
        systemAudioLostAt = try container.decodeIfPresent(String.self, forKey: .systemAudioLostAt)
        systemAudioRestoredAt = try container.decodeIfPresent(String.self, forKey: .systemAudioRestoredAt)
        systemAudioLossCount = try container.decodeIfPresent(Int.self, forKey: .systemAudioLossCount)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(micIncluded, forKey: .micIncluded)
        try container.encodeIfPresent(exactZeroSeconds, forKey: .exactZeroSeconds)
        try container.encodeIfPresent(tapRebuilds, forKey: .tapRebuilds)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(errorClass, forKey: .errorClass)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(attemptNumber, forKey: .attemptNumber)
        try container.encodeIfPresent(previousErrorClass, forKey: .previousErrorClass)
        try container.encodeIfPresent(backoffMS, forKey: .backoffMS)
        try container.encodeIfPresent(systemAudioLostAt, forKey: .systemAudioLostAt)
        try container.encodeIfPresent(systemAudioRestoredAt, forKey: .systemAudioRestoredAt)
        try container.encodeIfPresent(systemAudioLossCount, forKey: .systemAudioLossCount)
    }
}

/// architecture.md:1231 — `{"model_id": "whisper-large-v3-turbo",
/// "audio_duration_s": 1827, "transcript_chars": 23847}`. When the worker also
/// diarizes, its summary rides along under `diarize`: `PipelineStage` has no
/// `diarize` case, so the one `transcribe` row is where it is recorded.
public struct TranscribeMeta: Codable, Equatable, Sendable {
    public var modelID: String
    public var audioDurationSeconds: Int
    public var transcriptChars: Int
    public var diarize: DiarizeMeta?

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case audioDurationSeconds = "audio_duration_s"
        case transcriptChars = "transcript_chars"
        case diarize
    }

    public init(modelID: String, audioDurationSeconds: Int, transcriptChars: Int, diarize: DiarizeMeta? = nil) {
        self.modelID = modelID
        self.audioDurationSeconds = audioDurationSeconds
        self.transcriptChars = transcriptChars
        self.diarize = diarize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        audioDurationSeconds = try container.decode(Int.self, forKey: .audioDurationSeconds)
        transcriptChars = try container.decode(Int.self, forKey: .transcriptChars)
        diarize = try container.decodeIfPresent(DiarizeMeta.self, forKey: .diarize)
    }

    /// `diarize` is omitted, not written as null, when no diarization step
    /// ran, so a row without one keeps its original shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(audioDurationSeconds, forKey: .audioDurationSeconds)
        try container.encode(transcriptChars, forKey: .transcriptChars)
        try container.encodeIfPresent(diarize, forKey: .diarize)
    }
}

/// What the diarization step reports inside the `transcribe` row's metadata.
public struct DiarizeMeta: Codable, Equatable, Sendable {
    public var modelID: String
    public var segmentCount: Int
    public var speakerCount: Int
    public var snippetCount: Int

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case segmentCount = "segment_count"
        case speakerCount = "speaker_count"
        case snippetCount = "snippet_count"
    }

    public init(modelID: String, segmentCount: Int, speakerCount: Int, snippetCount: Int) {
        self.modelID = modelID
        self.segmentCount = segmentCount
        self.speakerCount = speakerCount
        self.snippetCount = snippetCount
    }
}

/// architecture.md:1232 — `{"model_id": "claude-haiku-4-5", "input_tokens":
/// ..., "output_tokens": ..., "cost_usd": ..., "suggestions_count": ...,
/// "review_skipped": false}`. When `diarization_review.enabled = false`,
/// callers populate the flag-off contract instead (`model_id: "flag_off"`,
/// zeroed counters, `review_skipped: true`) rather than this type gaining a
/// separate case — it's the same shape either way.
public struct ReviewDiarizationMeta: Codable, Equatable, Sendable {
    public var modelID: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var suggestionsCount: Int
    public var reviewSkipped: Bool

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
        case suggestionsCount = "suggestions_count"
        case reviewSkipped = "review_skipped"
    }

    public init(
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        costUSD: Double,
        suggestionsCount: Int,
        reviewSkipped: Bool,
    ) {
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.suggestionsCount = suggestionsCount
        self.reviewSkipped = reviewSkipped
    }
}

/// No example shape exists yet for `attribute` — real fields are the future
/// Attribute-stage story's own call.
public struct AttributeMeta: Codable, Equatable, Sendable {
    public init() {}
}

/// architecture.md:1233 — `{"model_id": "claude-opus-5", "effort_budget":
/// "medium", "input_tokens": ..., "output_tokens": ..., "thinking_tokens":
/// ..., "cost_usd": ..., "quote_validation_drop_count": ...,
/// "grounding_method": "..."}`. `fallback_triggered` says whether the
/// fallback strategy produced the summary; `fallback_error_class` is the
/// stable class of the primary strategy's failure that caused it, and is
/// absent when no fallback ran. `cost_ceiling_usd` is the NFR-C1 ceiling the
/// call was measured against and `cost_ceiling_exceeded` whether `cost_usd`
/// was above it; both are absent on rows written before the check existed.
public struct SummarizeMeta: Codable, Equatable, Sendable {
    public var modelID: String
    public var effortBudget: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var thinkingTokens: Int
    public var costUSD: Double
    public var quoteValidationDropCount: Int
    public var groundingMethod: String
    public var fallbackTriggered: Bool
    public var fallbackErrorClass: String?
    public var costCeilingUSD: Double?
    public var costCeilingExceeded: Bool?

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case effortBudget = "effort_budget"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case thinkingTokens = "thinking_tokens"
        case costUSD = "cost_usd"
        case quoteValidationDropCount = "quote_validation_drop_count"
        case groundingMethod = "grounding_method"
        case fallbackTriggered = "fallback_triggered"
        case fallbackErrorClass = "fallback_error_class"
        case costCeilingUSD = "cost_ceiling_usd"
        case costCeilingExceeded = "cost_ceiling_exceeded"
    }

    public init(
        modelID: String,
        effortBudget: String,
        inputTokens: Int,
        outputTokens: Int,
        thinkingTokens: Int,
        costUSD: Double,
        quoteValidationDropCount: Int,
        groundingMethod: String,
        fallbackTriggered: Bool,
        fallbackErrorClass: String?,
        costCeilingUSD: Double? = nil,
        costCeilingExceeded: Bool? = nil,
    ) {
        self.modelID = modelID
        self.effortBudget = effortBudget
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thinkingTokens = thinkingTokens
        self.costUSD = costUSD
        self.quoteValidationDropCount = quoteValidationDropCount
        self.groundingMethod = groundingMethod
        self.fallbackTriggered = fallbackTriggered
        self.fallbackErrorClass = fallbackErrorClass
        self.costCeilingUSD = costCeilingUSD
        self.costCeilingExceeded = costCeilingExceeded
    }
}

/// architecture.md:1234 — `{"vault_note_path": "...",
/// "frontmatter_schema_version": 1}`.
public struct PersistMeta: Codable, Equatable, Sendable {
    public var vaultNotePath: String
    public var frontmatterSchemaVersion: Int

    enum CodingKeys: String, CodingKey {
        case vaultNotePath = "vault_note_path"
        case frontmatterSchemaVersion = "frontmatter_schema_version"
    }

    public init(vaultNotePath: String, frontmatterSchemaVersion: Int) {
        self.vaultNotePath = vaultNotePath
        self.frontmatterSchemaVersion = frontmatterSchemaVersion
    }
}

/// architecture.md:1235 — `{"notification_id": "...", "delivered":
/// true|false}`.
public struct NotifyMeta: Codable, Equatable, Sendable {
    public var notificationID: String
    public var delivered: Bool

    enum CodingKeys: String, CodingKey {
        case notificationID = "notification_id"
        case delivered
    }

    public init(notificationID: String, delivered: Bool) {
        self.notificationID = notificationID
        self.delivered = delivered
    }
}
