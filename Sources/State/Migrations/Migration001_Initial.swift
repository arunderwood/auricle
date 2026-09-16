import GRDB

/// Migration #1: the entire schema in one pass — all five canonical tables,
/// the `meetings_updated_at` trigger, and all three indexes — verbatim from
/// architecture.md Decision 2.1 (lines 691-774). Every `telemetry` counter
/// column ships here, including columns with no MVP writer yet, so no later
/// epic ever needs a migration to add one (Amelia's Story 1 blocker).
///
/// The whole block is raw SQL, not GRDB's typed table builder: the partial
/// indexes need `WHERE` clauses the builder doesn't support
/// (architecture.md:797), and one literal block keeps this file a faithful
/// transcription of the architecture document rather than a
/// hand-reconstruction of it.
enum Migration001Initial {
    static let identifier = "001_initial"

    static func migrate(_ db: Database) throws {
        try db.execute(sql: schemaSQL)
    }

    private static let schemaSQL = """
    -- Migration tracking; owned exclusively by GRDB.DatabaseMigrator. No application code writes this.
    CREATE TABLE schema_version (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL                   -- ISO8601 UTC, 'YYYY-MM-DDTHH:MM:SSZ'
    );

    -- One row per captured meeting; the meeting's lifecycle anchor.
    CREATE TABLE meetings (
        id TEXT PRIMARY KEY,                       -- ULID (Crockford base32, 26 chars), e.g. '01HJK3PQXY7N8M...'
        state TEXT NOT NULL,                       -- canonical state name from Decision 1.2
        created_at TEXT NOT NULL,                  -- ISO8601 UTC
        updated_at TEXT NOT NULL,                  -- ISO8601 UTC; maintained by AFTER UPDATE trigger (see below)
        capture_started_at TEXT,                   -- ISO8601 UTC; set by capture stage on record start
        capture_ended_at TEXT,                     -- ISO8601 UTC; set by capture stage on stop
        duration_seconds INTEGER,                  -- NULL until capture_ended_at is set; CHECK (duration_seconds >= 0) when set
        title TEXT,                                -- initial from calendar enrichment or generic 'Meeting at <ts>'; refined by summarize sub-step
        calendar_event_id TEXT,                    -- 'google:abc...' format, namespace-prefixed for future CalendarSource implementations
        vault_note_path TEXT,                      -- absolute vault path; set by persist; updated to latest publish on re-publish
        audio_cache_path TEXT,                     -- absolute path under cache-dir; set by capture; immutable once set
        verified_at TEXT,                          -- ISO8601 UTC; set by verify (notification click handler) or `auricle keep <id>`
        retention_policy TEXT                      -- NULL = use global config at timer-arm time; non-NULL = explicit override ('indefinite' or 'custom:<days>')
    );
    -- Partial index on active states for fast pending-list queries
    CREATE INDEX idx_meetings_state ON meetings(state)
      WHERE state NOT IN ('verified','retention_expired','discarded');

    -- Append-only stage event log; replayable for audit and forensic crash analysis
    CREATE TABLE stage_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        stage TEXT NOT NULL,                       -- 'capture'|'transcribe'|'attribute'|'summarize'|'persist'|'notify'|'verify'|'discard'
        event TEXT NOT NULL,                       -- 'started'|'completed'|'failed'|'retried'
        occurred_at TEXT NOT NULL,                 -- ISO8601 UTC
        duration_ms INTEGER,                       -- only set on 'completed'/'failed' events
        error_message TEXT,                        -- only set on 'failed' events
        metadata_json TEXT                         -- stage-specific structured data, e.g. {"cost_usd":0.32,"thinking_tokens":3200}
    );
    CREATE INDEX idx_stage_events_meeting ON stage_events(meeting_id, occurred_at);

    -- Retention timer queue; one row per meeting once verification fires
    CREATE TABLE retention_timers (
        meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
        armed_at TEXT NOT NULL,                    -- ISO8601 UTC; verification click timestamp
        fires_at TEXT NOT NULL,                    -- ISO8601 UTC; when audio should be deleted
        last_reminded_at TEXT,                     -- ISO8601 UTC; for 7d / 14d escalation reminders
        status TEXT NOT NULL DEFAULT 'pending'     -- 'pending'|'fired'|'overridden'
    );
    CREATE INDEX idx_retention_pending_fires_at ON retention_timers(fires_at) WHERE status = 'pending';

    -- Per-meeting telemetry rollup; one row populated incrementally via UPSERT (different stages contribute different columns)
    CREATE TABLE telemetry (
        meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
        time_to_attribution_ready_seconds INTEGER,  -- machine-time only: awaiting_attribution.entered_at - capture.completed_at (the part NFR-P1 budgets)
        time_to_vault_note_seconds INTEGER,         -- user-perceived end-to-end: notify.completed_at - capture.completed_at (includes user-paced attribute time)
        transcription_wer_estimate REAL,
        quote_validation_drop_count INTEGER,
        attribution_completion_path TEXT,          -- 'inline_ui'|'cli_speakers_flag'|'publish_anyway'
        summarization_path TEXT,                   -- 'claude_api'|'local_llm'
        summarization_model TEXT,                  -- 'claude-opus-5'|'claude-sonnet-X'|'ollama:...'
        summarization_effort_budget TEXT,          -- 'low'|'medium'|'high'|'xhigh'|'max' (named levels only;
                                                    -- no numeric-token-budget option on this model generation's API)
        cost_usd REAL,                             -- summarize stage cost only (Opus); see *_cost_usd siblings below for AI-reviewer costs
        -- AI-reviewer category telemetry (Decision Group 5; sparse — populated only when corresponding feature runs)
        diarization_suggestions_count INTEGER,         -- count of AI-proposed corrections emitted by reviewer
        diarization_suggestions_applied_count INTEGER, -- count user accepted (per-suggestion Apply or Apply all)
        diarization_suggestions_rejected_count INTEGER,-- count user explicitly rejected
        diarization_review_cost_usd REAL,              -- Haiku cost for the review pass; '0' for local-LLM impls (Decision 5.6)
        diarization_review_model TEXT,                 -- 'claude-haiku-4-5' | 'local:<name>' (Decision 5.6 telemetry contract)
        -- Transcription review category (Decision 5.5 Phase 3 — declared, sparse in MVP)
        transcription_suggestions_count INTEGER,
        transcription_suggestions_applied_count INTEGER,
        transcription_suggestions_rejected_count INTEGER,
        transcription_review_cost_usd REAL,
        transcription_review_model TEXT,
        audio_retention_status_at_30d TEXT         -- backfilled by a periodic retention scheduler
    );

    -- Trigger: maintain meetings.updated_at automatically (removes a class of bug)
    CREATE TRIGGER meetings_updated_at AFTER UPDATE ON meetings
    BEGIN
        UPDATE meetings SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = NEW.id;
    END;
    """
}
