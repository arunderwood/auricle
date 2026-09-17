# Epic 3 Context: Quote-Grounded Summarization Engine

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Given a canonical transcript, a vault-derived glossary, and (when available) a matched calendar event, auricle produces a validated summary whose every action item and decision is grounded in a verifiable pointer back into the source transcript — never a paraphrase. Ungrounded items are dropped, never rendered. This is the highest-risk epic in the project: it delivers the core AI wedge (quote-grounded extraction + jargon correction), the two inputs that feed it (calendar enrichment, vault glossary), a one-time smoke test that empirically picks the MVP default grounding strategy, and a continuous regression harness that prevents silent quality drift once real audio lands in Epic 4.

## Stories

- Story 3.1: SummarizerInterface — Protocol + normalized `SummaryWithGrounding` output shape
- Story 3.2: SummarizationPromptBuilder — file-backed prompt set + glossary injection + drift snapshot tests
- Story 3.3: AnthropicHTTPClient + KeychainAPIKey + retry/backoff
- Story 3.4: ClaudeSubstringSummarizer + SubstringGroundingValidator
- Story 3.5: ClaudeCitationsSummarizer + CitationGroundingValidator + canonicalization invariant tests
- Story 3.6: SummarizerOrchestrator — primary/fallback wiring
- Story 3.7: Summarize stage entry point + cache-dir handoff
- Story 3.8: Decision 3.6 smoke-test execution + decision-rule lock-in
- Story 3.9: Pipeline regression harness — frozen transcripts + stubbed responses
- Story 3.10: GoogleCalendarSource + OAuth PKCE + Keychain refresh-token + EventMatcher
- Story 3.11: Calendar enrichment graceful degradation
- Story 3.12: VaultGlossaryBuilder + GlossaryInjector + JargonCorrectionStrategy

## Requirements & Constraints

- Every action item and decision must carry a verifiable grounding pointer (character/block range into the canonical transcript); items that fail validation are dropped before the note is written — this is a hard gate, not a warning.
- Anthropic Claude is the default and only MVP summarization engine (local-LLM path is v1.1+, same output contract).
- One primary Claude call per meeting, with at most one automatic fallback call; total per-meeting cost stays bounded even across primary + fallback.
- Calendar enrichment (event title/attendees) and vault-glossary injection are inputs to summarization, not separate user-facing stages; both must degrade gracefully rather than block note publication.
- Secrets (Anthropic API key, Google OAuth refresh token) live only in Keychain, read at call time, never cached to disk or env vars; all network calls use TLS 1.2+.
- Google Calendar OAuth scope is read-only and minimum-necessary; attendee emails are stripped before anything reaches a prompt.
- Anthropic response bodies and API keys are never passed to the logging facade — only redacted metadata (status, token counts, cost, model id).
- Model identifier and effort level are user-configurable without a rebuild; default is `claude-opus-5` at `medium` effort.
- Cost ceiling (~$0.50/30-min meeting at the default tier) is enforced against auricle's own token-count × rate-table computation, not a third-party self-reported cost figure — that computation is auditable and correctable by the maintainer.
- Summarize runs as an isolated subprocess (network calls may hang; must not freeze the GUI) and is independently invocable from the CLI.

## Technical Decisions

- **Direct API, not an agent session.** The summarize stage calls the Anthropic Messages API directly from Swift via a hand-rolled HTTP client — deliberately not a managed Claude Code/Agent-SDK session. The stage is a one-shot, bounded extraction (transcript + glossary in, structured items out) with a validator waiting on the result; a session's advantages (multi-step tool use, skill discovery) buy nothing here and would add an unaudited dependency, model-selection footguns, and a code path the grounding validator never sees. This ruling is scoped to the summarize stage only — it does not bind other AI-invocation points in later epics.
- **Normalized grounding shape.** All strategies (Citations, substring, future local-LLM) produce the same `SummaryWithGrounding` / `GroundedItem` / `GroundingPointer` shape. `GroundingPointer` carries a transcript start/end range plus a `sourceMethod` tag used only for telemetry, never as a downstream control flag. There is no raw-response field anywhere in the shared contract — each strategy translates internally.
- **Citations mechanics (load-bearing, empirically verified against the live API):** the transcript is submitted as a custom content document, one content block per utterance; structured JSON is requested by prompt instruction, never via `output_config.format` (the API returns 400 when both are combined). Anthropic returns `content_block_location` block indices (zero-indexed, exclusive end) rather than character offsets; auricle maps each index to its own known character range. This deletes the offset-encoding question rather than translating it — no character index crosses the API boundary in either direction, so no Unicode-convention mismatch between strategies is possible by construction. A block index out of range is treated as a malformed response, not clamped.
- **Orchestrator-mediated fallback.** A `SummarizerOrchestrator` actor — not in-strategy retry — decides whether to fall back from Citations to substring. Only specific typed errors (`citationsUnavailable`, `malformedResponse`, `rateLimited`, `featureToggleDisabled`) trigger fallback; network/auth/quota errors are re-thrown untouched. Fallback is bounded to one attempt with no chaining.
- **Prompts live in files, not Swift string literals**, in two tiers: a shipped, snapshot-tested default set in-repo, and a user override directory at `~/.auricle/prompts/summarize/` that the test suite never reads. A `--prompt-dir` CLI flag overrides both per run for prompt iteration without a rebuild. The builder computes a SHA-256 over the resolved prompt files and writes it to telemetry (`summarization_prompt_set_hash`), surfaced via `auricle status <id>` — this is how "why did this note come out worse" becomes answerable once prompts are user-editable. The user-facing override ships unflagged in MVP by deliberate maintainer decision (contrast with Epic 4's flag-gated diarization review): a feature that restricts the maintainer's access to his own editing surface needs a much higher bar than one that only adds observability.
- **Prompt caching:** system prompt, glossary, and attendee context use `cache_control` breakpoints; the transcript itself is never cached (unique per meeting).
- **Glossary scoping must be fuzzy, not exact-match.** An ASR-mangled term (e.g. "mesh core" for `meshcore`) has no exact transcript mention — an exact-match scoping rule would drop precisely the terms jargon correction exists to fix. Acceptable implementations: fuzzy/phonetic matching, or keeping People/Projects unconditionally and scoping only Concepts.
- **Smoke test picks the MVP default empirically**, not by assumption: ≥5 real meeting transcripts run through both strategies; the comparison axis is parameterized as (strategy, prompt-set) rather than hard-coded, so the same rig later answers prompt-quality questions. Default flips to substring if it catches anything Citations misses on any fixture (trust-asymmetry: a missed commitment is far costlier than a slightly weaker validator).
- **The regression harness (Story 3.9) is intentionally not a quality/prompt-comparison tool.** It uses stubbed, deterministic Anthropic responses so the same fixture always returns the same bytes — a prompt change cannot move it. Prompt-quality comparison belongs to Story 3.8's rig only.

## UX & Interaction Patterns

- Grounded items are shown by rendering the cited transcript text inline as a `> source quote` Obsidian blockquote directly beneath each action item/decision — trust is demonstrated in the note itself, not asserted.
- No confidence flags or grounding-method indicators appear in vault frontmatter. Trust calibration (does the user come to rely on auricle's notes) happens entirely through CLI inspection — `auricle status <id>` — not through any GUI or in-vault UI; this epic ships no GUI surface.

## Cross-Story Dependencies

- Story 3.8 (smoke-test execution) is sequenced after Stories 3.1–3.6 (interface, both strategies, orchestrator) but before Story 3.7 (stage entry point), because the orchestrator's primary/fallback wiring depends on the smoke-test outcome.
- Story 3.5's canonicalization invariant test extends the `CanonicalTranscript` round-trip test Story 3.1 added — Story 1.2 deferred the type itself (per `deferred-work.md`), so Story 3.1 is its first real consumer, not Story 1.2.
- Story 3.7 composes Story 3.2 (prompt builder), Story 3.6 (orchestrator), Stories 3.10/3.11 (calendar enrichment), and Story 3.12 (glossary) into the subprocess entry point.
- Calendar enrichment failure (Story 3.11) changes what the persist stage (Epic 2) writes into frontmatter (generic title, empty attendees, `needs-calendar-enrichment` tag) — the note must still parse correctly via Epic 2's `FrontmatterReader`.
- `auricle doctor` (Epic 9) is expected to warn when the prompt override directory is not under version control, and to surface a missing Anthropic API key.
