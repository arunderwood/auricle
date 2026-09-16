---
date: 2026-09-16
project: auricle
workflow: correct-course
trigger_story: none (Epic 3 is backlog; discovered via a follow-up dependency-staleness audit, at your request to look beyond the three already-corrected packages)
scope_classification: minor
status: applied
applied: 2026-09-16
artifacts_affected:
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/epics.md
  - _bmad-output/planning-artifacts/architecture.md
  - Package.swift
---

# Sprint Change Proposal — Claude Model Defaults & Effort Parameter Vocabulary

## 1. Issue Summary

### Problem statement

Two related staleness findings, plus one unrelated minor one, surfaced by extending today's dependency-staleness audit (which already produced the GRDB, WhisperKit/SpeakerKit, and Swift-tools-version corrections) to the project's other pinned external surface: the Anthropic Claude API.

**Finding A — stale default model generation.** `prd.md`, `epics.md`, and `architecture.md` hardcode `claude-opus-4-7` (summarization default, ~14 occurrences) and `claude-sonnet-4-6` (one occurrence, `architecture.md:84`) as of NFR-I6. Both are now **legacy models** — the current generation is Claude Opus 5 (`claude-opus-5`) and Claude Sonnet 5 (`claude-sonnet-5`). `claude-haiku-4-5` (used for `ClaudeDiarizationReviewer`) is unaffected — it's still the current Haiku.

**Finding B — the "effort budget" vocabulary the spec assumes doesn't exist on the real API.** `architecture.md:749` and `epics.md:1369` define the `summarization_effort_budget` value space as `'minimal'|'low'|'moderate'|'high' or numeric token count`. The real Anthropic API's `effort` parameter (the mechanism that replaced manually-configured extended-thinking budgets starting with the 4.6 generation) accepts exactly five named levels — `low` / `medium` / `high` / `xhigh` / `max` — and **no numeric value at all**. Three mismatches: no `minimal` level exists; `moderate` isn't a real level (`medium` is the nearest analogue); and the "or numeric token count" escape hatch the PRD designed in doesn't exist on the current API — that was the old `thinking: {type: "enabled", budget_tokens: N}` mechanism, which Anthropic's own docs state is **deprecated on Claude Opus 4.6 / Sonnet 4.6 and not accepted on later models** — including the Opus 5 / Sonnet 5 that Finding A recommends defaulting to.

**Finding C — unrelated, minor.** The commented-out Sparkle dependency (`Package.swift:9`, deferred to v1.1 per AR-INIT-2) cites `2.6.0`; latest is `2.10.0`. Not yet in the build.

### How it was discovered

You asked to look for other high-ROI upgrades to fold into the spec, following the same pattern as today's GRDB/WhisperKit/Swift-version corrections. Extending the same "check every pinned external dependency against upstream reality" method from SwiftPM packages to the project's other externally-versioned dependency — the Anthropic Messages API — surfaced Finding A; reading Anthropic's own parameter documentation while verifying Finding A surfaced Finding B as a direct consequence.

### Evidence

- `platform.claude.com/docs/en/models/overview` (fetched live): current lineup is Claude Fable 5.1, **Claude Opus 5** (`claude-opus-5`), **Claude Sonnet 5** (`claude-sonnet-5`), Claude Haiku 4.5 (`claude-haiku-4-5`, dated snapshot `claude-haiku-4-5-20251001`). Legacy models still available include `Claude Opus 4.7` and `Claude Sonnet 4.6` — confirming both current spec defaults are one full generation behind, not hypothetical drift.
- Same page: "Every Claude model ID is a pinned snapshot, including the dateless IDs used from the 4.6 generation on" — `claude-opus-4-7` and `claude-sonnet-4-6` were already correctly-shaped dateless IDs; this proposal's replacements (`claude-opus-5`, `claude-sonnet-5`) follow the same dateless convention, confirmed current.
- `platform.claude.com/docs/en/build-with-claude/effort` (fetched live): effort levels are `low` / `medium` / `high` / `xhigh` / `max`; API default is `high`; "the only extended-thinking-only model that supports effort" alongside `budget_tokens` is `claude-opus-4-5` specifically — every model this spec targets (4.6-generation and later) uses effort levels only, no numeric budget.
- Same page, "Effort with thinking" section: extended thinking's manual `thinking.type = "enabled"` + `budget_tokens` mode "is deprecated on Claude Opus 4.6 and Claude Sonnet 4.6 and not accepted on later models" — directly invalidates the "or numeric token count" branch of `architecture.md:749`'s column comment and `epics.md:1369`'s AC for any model this spec would actually default to.
- Web search (`claude.com/blog/introducing-citations-api`; `platform.claude.com/docs/en/api/models/list`): Citations API — the mechanism `ClaudeCitationsSummarizer` (Decision 3.2) is built around — **is confirmed supported on Claude Opus 5**. This is not a new open question; Finding A doesn't threaten Decision 3.2's architecture, only its model-identifier literals.
- `gh api repos/sparkle-project/Sparkle/releases` → latest `2.10.0` (2026-09-13) vs. the deferred comment's `2.6.0`.
- `_bmad-output/implementation-artifacts/sprint-status.yaml`: `epic-3: backlog`, all of Epic 3's stories (3.1–3.12) `backlog`. No code anywhere imports `AnthropicHTTPClient` or calls `messages.create` yet.

### Explicitly NOT part of this issue

- **`architecture.md:84`'s pre-existing Sonnet-vs-Opus inconsistency is not resolved here.** That line names `claude-sonnet-4-6` as the "Anthropic SDK" default, while NFR-I6 (the binding requirement, restated in `epics.md:200` and traced in `epics.md:562`) names `claude-opus-4-7`. This discrepancy predates this proposal. This proposal bumps `architecture.md:84`'s generation number in place (`sonnet-4-6` → `sonnet-5`) without deciding which family is actually the default — that's a separate, substantive correction outside a version-staleness fix.
- **The exact effort level to use as the new default is not decided here.** The PRD's own mechanism for this — the summarization spike (prd.md Open Resolutions) — already defers the precise "moderate-equivalent" value to empirical tuning. This proposal only fixes the *value space* Story 3.3 and the telemetry schema draw from (`low`/`medium`/`high`/`xhigh`/`max`, no numeric option) so the spike tunes within a value space that actually exists on the API. Placeholder narrative occurrences (e.g., "moderate default") are updated to `medium` as the closest analogue, explicitly flagged as spike-revisable, not as a locked decision.
- **`Package.swift`'s Sparkle line is a comment only** (AR-INIT-2 defers the real dependency to v1.1) — this proposal updates the comment's cited version, nothing executable.
- **No FR is added, removed, or renumbered.** NFR-I6's binding requirement (model + effort are configurable per FR58, tunable without a schema change) is unchanged — only the stated default value and the value space it's drawn from.
- **The Citations-vs-substring architectural decision (Decision 3.2) is unchanged** — both strategies still ship at MVP; only the model literal each calls changes.

---

## 2. Impact Analysis

### Epic impact

| Epic | Impact | Detail |
|---|---|---|
| Epic 3 (Summarize) | **Story 3.3, 3.4, 3.5, 3.7 AC amendments; AR-SUM-2 wording** | Model default and effort-vocabulary corrections only — no strategy, protocol, or fallback logic changes |
| Epic 5 (AI-assisted correction / diarization review) | **None** | `claude-haiku-4-5` is unaffected; this proposal doesn't touch it |
| Epic 1–2, 4, 6–10 | **None** | No other epic references a Claude model identifier or the effort-budget value space |

Epic scope, count, sequencing, and priority are **unchanged**. Epic 3 is `backlog` — nothing built, nothing to roll back.

### Artifact conflicts

- **PRD** — NFR-I6, NFR-C1, and the two related Open Resolutions / "decisions that may need re-resolution" bullets update their default-model and effort-vocabulary text. FR29/FR30/FR31/FR32/FR33/FR58 text is untouched.
- **Architecture** — external-dependencies bullet (`architecture.md:84`), the `summarization_model`/`summarization_effort_budget` SQL comments (`architecture.md:748-749`), the `summarize` stage-events payload example (`architecture.md:1230`), and Decision 3.2's two `messages.create` call descriptions (`architecture.md:1354, 1361`) all update.
- **Epics** — NFR-I6/NFR-C1 restatements, AR-SUM-2, the traceability table row, and four Story ACs (3.3, 3.4, 3.5, 3.7) update.
- **`Package.swift`** — one comment line (Sparkle version cite).
- **UX spec** — no conflict; `ux-design-specification.md:879`'s "Claude Opus ~60s" sequence-diagram label names no specific model version and needs no edit.

### Technical impact

None yet — Epic 3 hasn't started, and no code anywhere calls the Anthropic API. Forward effect: whoever implements Story 3.3 (`SummarizerConfig`) builds its effort-budget field against a value space that actually exists on the API, instead of discovering the mismatch mid-implementation when the numeric-override branch the AC describes turns out to be unimplementable against the real API.

---

## 3. Recommended Approach

### Selected path: Direct Adjustment (Option 1)

**Effort: Low** — mechanical text corrections across four files, no code. **Risk: Low** — Epic 3 not started; corrected value space is verified against live Anthropic documentation, not asserted. **Timeline impact: None.**

### Rationale

Same mechanism as today's other three corrections: don't decide the empirical question (which effort level becomes the actual default) that the PRD already has a spike planned for — just make sure the spec's stated defaults and value spaces reflect current upstream reality before that spike runs, so it tunes within a real option set instead of a fictional one.

---

## 4. Detailed Change Proposals

### 4.1 prd.md — NFR-I6 (line 673)

```
OLD: - **NFR-I6 [MVP]:** auricle integrates with the Anthropic Messages API. The model identifier and
       extended-thinking effort budget are both configurable; default at MVP is `claude-opus-4-7` with
       extended thinking enabled at a moderate default effort budget. Both knobs are tunable via config
       (per FR58) without code changes — users may dial effort down to reduce cost / latency, dial up for
       higher-quality summarization on important meetings, or switch to a smaller model variant entirely
       (e.g., latest Claude Sonnet or Haiku) for cost-sensitive workloads. Updating the default model or
       effort budget in a release is a release-note bump, not a frontmatter-schema change. The exact
       moderate-default effort budget value is empirically tuned during the summarization spike (see Open
       Resolutions).

NEW: - **NFR-I6 [MVP]:** auricle integrates with the Anthropic Messages API. The model identifier and
       effort level are both configurable; default at MVP is `claude-opus-5` at `medium` effort (the
       current generation's named effort levels are `low`/`medium`/`high`/`xhigh`/`max` — there is no
       numeric token-budget override on this model generation; the manual extended-thinking budget
       mechanism this NFR originally assumed is deprecated on Claude Opus/Sonnet 4.6 and not accepted on
       later models, per Anthropic's effort-parameter documentation). Both knobs are tunable via config
       (per FR58) without code changes — users may dial effort down to reduce cost / latency, dial up for
       higher-quality summarization on important meetings, or switch to a smaller model variant entirely
       (e.g., latest Claude Sonnet or Haiku) for cost-sensitive workloads. Updating the default model or
       effort level in a release is a release-note bump, not a frontmatter-schema change. The exact default
       effort level is empirically tuned during the summarization spike (see Open Resolutions) from among
       the levels the API actually supports.
```

### 4.2 prd.md — NFR-C1 (line 705)

```
OLD: ...the default model selection (`claude-opus-4-7` for summarize with moderate extended-thinking effort
     budget per NFR-I6, Haiku-default for correction reviewers)...
     ...(b) reduce extended-thinking effort budget toward zero (lowest effort approaches a no-thinking
     baseline of approximately ~\$0.15/meeting)...

NEW: ...the default model selection (`claude-opus-5` at `medium` effort per NFR-I6, Haiku-default for
     correction reviewers)...
     ...(b) reduce effort toward `low` (the lowest available level approaches a minimal-thinking baseline of
     approximately ~\$0.15/meeting)...
```

### 4.3 prd.md — Citations vs substring grounding resolution (line 725)

```
OLD: ...commit the architecture to a dual-strategy `GroundingValidator` (Citations primary on
     `claude-opus-4-7`; substring fallback...)... Citations API confirmed supported on `claude-opus-4-7`.

NEW: ...commit the architecture to a dual-strategy `GroundingValidator` (Citations primary on
     `claude-opus-5`; substring fallback...)... Citations API confirmed supported on `claude-opus-5`
     (Anthropic's Citations API documentation and current model list both confirm Opus 5 support — this
     doesn't reopen the dual-strategy decision, only updates which model literal it's confirmed against).
```

### 4.4 prd.md — Default Claude model and effort budget (line 743)

```
OLD: - **Default Claude model and extended-thinking effort budget.** Default at MVP is `claude-opus-4-7`
       with extended thinking enabled at a moderate effort budget (per NFR-I6). The exact moderate-default
       budget value is empirically tuned during the summarization spike (see "Anthropic Citations API vs.
       free-form quote + grep validation" in Verify-before-implementing flags), measured against drop rate,
       recall, latency, and per-meeting cost. New Opus / Sonnet / Haiku releases should be evaluated for the
       cost/quality trade-off before becoming the new default; the model identifier and effort budget are
       configurable per-user (FR58, NFR-I6) so individual tuning does not require a release.

NEW: - **Default Claude model and effort level.** Default at MVP is `claude-opus-5` at `medium` effort (per
       NFR-I6) — `claude-opus-4-7`, this document's original default, is now a legacy model per Anthropic's
       current model lineup, and the current API's effort levels (`low`/`medium`/`high`/`xhigh`/`max`) have
       no numeric-budget equivalent to the "or numeric" option this line originally allowed for. The exact
       default effort level is empirically tuned during the summarization spike (see "Anthropic Citations
       API vs. free-form quote + grep validation" in Verify-before-implementing flags), measured against
       drop rate, recall, latency, and per-meeting cost. New Opus / Sonnet / Haiku releases should continue
       to be evaluated for the cost/quality trade-off before becoming the new default — this proposal is
       exactly one such evaluation; the model identifier and effort level are configurable per-user (FR58,
       NFR-I6) so individual tuning does not require a release.
```

### 4.5 epics.md — NFR-I6 restated (line 200)

```
OLD: - **NFR-I6 [MVP]:** auricle integrates with the Anthropic Messages API. The model identifier and
       extended-thinking effort budget are both configurable; default at MVP is `claude-opus-4-7` with
       extended thinking enabled at a moderate default effort budget. Both knobs are tunable via config
       (per FR58) without code changes.

NEW: - **NFR-I6 [MVP]:** auricle integrates with the Anthropic Messages API. The model identifier and
       effort level are both configurable; default at MVP is `claude-opus-5` at `medium` effort (named
       levels `low`/`medium`/`high`/`xhigh`/`max` — no numeric override on this model generation). Both
       knobs are tunable via config (per FR58) without code changes.
```

### 4.6 epics.md — NFR-C1 restated (line 226)

```
OLD: ...default model (`claude-opus-4-7` summarize, `claude-haiku-4-5` reviewers), prompt caching enabled.

NEW: ...default model (`claude-opus-5` summarize at `medium` effort, `claude-haiku-4-5` reviewers), prompt
     caching enabled.
```

### 4.7 epics.md — AR-SUM-2 (line 276)

```
OLD: - **AR-SUM-2:** Two MVP grounding strategies: `ClaudeCitationsSummarizer` (primary, Citations API on
       `claude-opus-4-7`) and `ClaudeSubstringSummarizer` (fallback + v1.1+ local-LLM path)...

NEW: - **AR-SUM-2:** Two MVP grounding strategies: `ClaudeCitationsSummarizer` (primary, Citations API on
       `claude-opus-5`) and `ClaudeSubstringSummarizer` (fallback + v1.1+ local-LLM path)...
```

### 4.8 epics.md — traceability table (line 562)

```
OLD: | NFR-I6 (Anthropic Messages API + configurable model + effort budget) | Epic 3 | `claude-opus-4-7`
     default; FR58 config knob |

NEW: | NFR-I6 (Anthropic Messages API + configurable model + effort level) | Epic 3 | `claude-opus-5`
     default at `medium` effort; FR58 config knob |
```

### 4.9 epics.md — Story 3.3, `SummarizerConfig` AC (line 1369)

```
OLD: **Then** it carries: model identifier (default `claude-opus-4-7` per NFR-I6), effort budget
     (`minimal`/`low`/`moderate`/`high` or numeric), Anthropic API key reference...

NEW: **Then** it carries: model identifier (default `claude-opus-5` per NFR-I6), effort level
     (`low`/`medium`/`high`/`xhigh`/`max` — named levels only; the current API has no numeric-budget
     override), Anthropic API key reference...
```

### 4.10 epics.md — Story 3.4, `ClaudeSubstringSummarizer` AC (line 1459)

```
OLD: **Then** the implementation calls `messages.create` on `claude-opus-4-7` (default per NFR-I6) via
     `AnthropicHTTPClient`...

NEW: **Then** the implementation calls `messages.create` on `claude-opus-5` (default per NFR-I6) via
     `AnthropicHTTPClient`...
```

### 4.11 epics.md — Story 3.5, `ClaudeCitationsSummarizer` AC (line 1490)

```
OLD: **Then** the implementation calls `messages.create` on `claude-opus-4-7` with the transcript provided
     as a Document with `citations: { enabled: true }` per Decision 3.2

NEW: **Then** the implementation calls `messages.create` on `claude-opus-5` with the transcript provided
     as a Document with `citations: { enabled: true }` per Decision 3.2
```

### 4.12 epics.md — Story 3.7, telemetry UPSERT AC (line 1573)

```
OLD: **Then** `telemetry` is updated via UPSERT per the write-authority matrix from AR-DATA-4:
     `summarization_path = "claude_api"`, `summarization_model = "claude-opus-4-7"`,
     `summarization_effort_budget = "moderate"` (or whatever was actually used), `cost_usd`,
     `quote_validation_drop_count`, `grounding_method` per Decision 4.5

NEW: **Then** `telemetry` is updated via UPSERT per the write-authority matrix from AR-DATA-4:
     `summarization_path = "claude_api"`, `summarization_model = "claude-opus-5"`,
     `summarization_effort_budget = "medium"` (or whatever was actually used), `cost_usd`,
     `quote_validation_drop_count`, `grounding_method` per Decision 4.5
```

### 4.13 architecture.md — external dependencies bullet (line 84)

```
OLD: - **Anthropic SDK / HTTPS client** — single Claude Messages API call per meeting. Configurable model
       identifier (default `claude-sonnet-4-6`). Stage is swappable per FR33.

NEW: - **Anthropic SDK / HTTPS client** — single Claude Messages API call per meeting. Configurable model
       identifier (default `claude-sonnet-5` — this line's Sonnet naming predates this proposal and
       disagrees with NFR-I6's Opus default elsewhere; only the generation number is corrected here, see
       §1 Explicitly NOT part of this issue). Stage is swappable per FR33.
```

### 4.14 architecture.md — SQL schema comments (lines 748–749)

```
OLD:     summarization_model TEXT,                  -- 'claude-opus-4-7'|'claude-sonnet-X'|'ollama:...'
         summarization_effort_budget TEXT,          -- 'minimal'|'low'|'moderate'|'high' or numeric token count

NEW:     summarization_model TEXT,                  -- 'claude-opus-5'|'claude-sonnet-X'|'ollama:...'
         summarization_effort_budget TEXT,          -- 'low'|'medium'|'high'|'xhigh'|'max' (named levels
                                                     -- only; no numeric-token-budget option on this model
                                                     -- generation's API)
```

### 4.15 architecture.md — `summarize` stage-events payload example (line 1230)

```
OLD: - `summarize`: `{"model_id": "claude-opus-4-7", "effort_budget": "moderate", "input_tokens": ...,
     "output_tokens": ..., "thinking_tokens": ..., "cost_usd": ..., "quote_validation_drop_count": ...,
     "grounding_method": "..."}`...

NEW: - `summarize`: `{"model_id": "claude-opus-5", "effort_budget": "medium", "input_tokens": ...,
     "output_tokens": ..., "thinking_tokens": ..., "cost_usd": ..., "quote_validation_drop_count": ...,
     "grounding_method": "..."}`...
```

### 4.16 architecture.md — Decision 3.2, concrete strategy descriptions (lines 1354, 1361)

```
OLD: **`ClaudeCitationsSummarizer` (MVP default):**
     - Calls `messages.create` on `claude-opus-4-7` with the transcript provided as a Document with
       `citations: { enabled: true }`
     ...
     **`ClaudeSubstringSummarizer` (MVP fallback + v1.1 local-LLM path):**
     - Calls `messages.create` on `claude-opus-4-7` (same prompt skeleton, no Citations enabled)...

NEW: **`ClaudeCitationsSummarizer` (MVP default):**
     - Calls `messages.create` on `claude-opus-5` with the transcript provided as a Document with
       `citations: { enabled: true }`
     ...
     **`ClaudeSubstringSummarizer` (MVP fallback + v1.1 local-LLM path):**
     - Calls `messages.create` on `claude-opus-5` (same prompt skeleton, no Citations enabled)...
```

### 4.17 Package.swift — Sparkle deferred-version comment (line 9)

```
OLD: // Sparkle: https://github.com/sparkle-project/Sparkle.git from: "2.6.0"

NEW: // Sparkle: https://github.com/sparkle-project/Sparkle.git from: "2.10.0"
```

---

## 5. Implementation Handoff

### Scope classification: Minor

No epic, story, or FR added, removed, or resequenced. No architectural commitment (AR-tag) added or removed — AR-SUM-2's wording changes, its substance (two grounding strategies, Citations primary) doesn't. Effort estimate: Low. Risk: Low — verified against live Anthropic documentation, not asserted; Citations API compatibility with the new default explicitly confirmed rather than assumed.

### Handoff

| Recipient | Responsibility |
|---|---|
| **This workflow** | Applies §4.1–§4.17 directly to `prd.md`, `epics.md`, `architecture.md`, `Package.swift`. |
| **Dev (Story 3.3, when Epic 3 starts)** | Builds `SummarizerConfig`'s effort field against the corrected value space (named levels only); runs the summarization spike to pick the actual default level from `low`/`medium`/`high`/`xhigh`/`max`, same deferred-decision pattern as the other MVP spikes. |

### Success criteria

1. No planning artifact asserts `claude-opus-4-7`, `claude-sonnet-4-6`, or a numeric effort/token-budget override as current — all now read `claude-opus-5` / `claude-sonnet-5` / named effort levels only.
2. `architecture.md`'s pre-existing Sonnet-vs-Opus default inconsistency (§1) is neither fixed nor worsened by this proposal — it's called out for a future, separate correction.
3. `sprint-status.yaml` — no change. Epic 3 stays `backlog`; no story added, removed, or renumbered.

### `sprint-status.yaml` impact

None.
