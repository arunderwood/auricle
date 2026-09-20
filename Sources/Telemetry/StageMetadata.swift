/// The per-stage `completed`-event payload types (architecture.md Decision
/// 4.5). A stage encodes its own `*Meta` struct directly and hands the string
/// to `StageRunner`'s `StageOutcome`, so the `metadata_json` a row stores is
/// the flat payload. This enum's wrapped encoding is never what a stage
/// writes. `verify`/`discard` have no case here; their events carry no typed
/// metadata.
///
/// `Codable` conformance is hand-written rather than compiler-synthesized:
/// Swift does not synthesize `Codable` for an enum with associated values, and
/// `capture`/`attribute`'s placeholder payloads are both content-identical
/// empty objects (`{}`) — indistinguishable by content alone, so the case
/// must be recovered from which keyed-container key is present, not from the
/// payload's shape.
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

/// No example shape exists yet for `capture` (Decision 4.5 gives concrete
/// JSON only for `transcribe`/`reviewDiarization`/`summarize`/`persist`/
/// `notify`) — real fields are the future Capture-stage story's own call.
public struct CaptureMeta: Codable, Equatable, Sendable {
    public init() {}
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
/// Attribute-stage story's own call (see `CaptureMeta`).
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
