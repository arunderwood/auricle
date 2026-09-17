# Epic 2 Context: Vault-Native Note Persistence

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Given a synthetic summary JSON, auricle writes a correctly-formatted Obsidian note into the vault: atomic, with a stable filename, versioned frontmatter schema, and never editing existing files. This epic is validated end-to-end against synthetic summary input (not live output from the summarization epic) — the goal is a hardened, self-contained vault-write capability that later epics plug real summarizer output into. Getting this right matters because the vault note is the durable, user-facing artifact of the whole product; corrupting or overwriting one is a data-loss bug in a tool whose entire premise is trustworthy plain-text persistence.

## Stories

- Story 2.1: FrontmatterRenderer — Data to Markdown with All Schema Variants
- Story 2.2: FilenameResolver — Slug Priority Chain, Normalization, and Edge Cases
- Story 2.3: VaultWriter — Atomic Write, Path Resolution, Collision Handling
- Story 2.4: Persist Stage Entry Point — Compose Renderer + Writer + Re-publish Semantics
- Story 2.5: Frontmatter Schema Versioning + Migration-Aware Reader

## Requirements & Constraints

- Every meeting is written as exactly one new markdown file at a configurable vault location; auricle never opens an existing vault file for write — all persistence is `temp file → fsync → atomic rename`, with zero partial-write events tolerated.
- Vault writes must complete in ≤500ms for a note up to 50KB of markdown.
- Rendered notes have a stable structure: frontmatter, one-paragraph summary, an Action Items section (each item with a supporting quote), a Decisions section (same structure), and a collapsed Transcript section at the bottom.
- Speakers are rendered as Obsidian `[[wikilinks]]` in body text, resolvable to existing or future people-notes.
- Filenames are stable and predictable, derived from date + meeting title, and must avoid collisions.
- The frontmatter schema is versioned (`schema_version`, present in every note); breaking changes bump the version and require the reader to keep handling every historical version ever shipped.
- Notes inherit standard vault file permissions; auricle never chmods existing files.
- auricle must remain compatible with current-major-release Obsidian via the `obsidian://open` URL scheme — no plugin dependency, no special vault config assumed.
- Quote-grounding is a hard gate upstream of persistence: every action item and decision that reaches the vault note must carry a quote that survives literal substring match against the transcript; failing items are dropped silently before persistence. Persist consumes already-grounded content — it does not re-validate quotes itself.

## Technical Decisions

- **Write authority.** All filesystem writes route through the single-implementation `AtomicWriter` (temp file → fsync → rename); a lint rule fails the build if raw file-write APIs appear outside it. `VaultWriter` wraps `AtomicWriter` with vault-path validation and never opens an existing vault file for write (enforced by lint rule + unit test). No caller may bypass `VaultWriter` to touch `vault_path/meetings_subdir/` directly.
- **Frontmatter is a narrow, intentional contract.** It carries only what a human reader, the Obsidian graph, or the `--reattribute` reader needs: title, date, tags, attendees as wikilinks, and an `auricle:` block limited to identity/lineage fields (`meeting_id`, `schema_version`, optional `supersedes`). Everything operational — timing telemetry, cost, model identifiers, retention timer state — lives in SQLite, never in frontmatter. Vault frontmatter also deliberately carries no confidence flags; trust/audit data is surfaced via the CLI (`auricle status`), not the vault note.
- **Variant tagging.** Baseline tag is `auricle/meeting`. `auricle/needs-attribution` is added when the user published without completing attribution (attendees/speakers render as `[[Speaker_N]]` placeholders). `auricle/needs-calendar-enrichment` is added when calendar lookup failed (title falls back to a generic `"Meeting at <local time>"`, attendees is an empty list). These combine independently; re-publish adds no special tag.
- **Filename convention:** `<YYYY-MM-DD local>-<slug>.md`. Slug source priority, falling through on empty/unusable result: (1) calendar event title, (2) `with-<attendee>[-and-<attendee>]` for ≤3 named attendees excluding self, (3) `meeting-at-<HHMM>` 24h local time, (4) `meeting-<first-8-chars-of-id>` defensive terminal fallback. Normalization: NFKD decompose → strip non-ASCII → lowercase → collapse non-alphanumerics to single hyphens → trim → cap at 60 chars (truncate at a hyphen boundary). Same-Mac same-day collisions get a single-hyphen ordinal suffix (`-2`, `-3`); cross-Mac collisions are an accepted, manually-recoverable trade-off (not solved by construction) since filenames were chosen to stay clean rather than embed a uniqueness token.
- **Re-publish semantics** (e.g. `auricle run <id> --reattribute`): the original vault note is never modified. A sibling file is written with a double-hyphen suffix, `<original-without-ext>--rerun-<YYYY-MM-DD local>[-N].md`, whose frontmatter carries `auricle.supersedes: "<original-filename>"` (filename only, no path). `meetings.vault_note_path` is updated to the latest publish; older publish paths remain reconstructible only via the `stage_events` audit log, not as a first-class query. If the original file was deleted by the user, re-publish falls back to a fresh, standard-named publish instead.
- **Vault path resolution:** two config knobs, `vault_path` (root, default `~/checkouts/SecondBrain`) and `meetings_subdir` (default `Meetings`), composed as `{vault_path}/{meetings_subdir}/<filename>.md`. `vault_path` must already exist and be writable — auricle never auto-creates it (a wrong auto-created vault is worse than a refused publish). `meetings_subdir` is auto-created if missing (auricle owns it); if it exists as a non-directory or a non-writable directory, the write fails fast with a clear error, surfaced by `auricle doctor` and on first publish.
- **Persist stage sequencing:** the entry point composes `FrontmatterRenderer → FilenameResolver → VaultWriter`, then updates `meetings.vault_note_path`, and transitions `meetings.state` from `summarizing` → `published` through the orchestrator's two-transaction pattern (Txn A on stage entry, Txn B on completion) — stages never write `meetings.state` or `stage_events` directly. A `stage_events` row (`stage='persist'`, `event='completed'`) records the vault path and schema version for the audit trail.
- **Schema versioning policy:** `schema_version` is required forever and its field name never changes. Additive fields under `auricle:` don't bump the version (readers ignore unknown fields). Breaking changes bump the version and require support for every historical version. The `--reattribute` reader dispatches on `schema_version` first; a version older than any ever shipped, or newer than the running binary supports, is a fail-fast error (the latter implying the user's Macs have drifted to different auricle versions).
- **Dependencies from Epic 1 (already built):** `Core.AtomicWriter` (atomic file writes), `State.StateStore` (typed SQLite read/write API), and `Orchestrator.StageRunner` (two-transaction stage lifecycle, crash recovery, retry). Epic 2 composes these; it does not reimplement them.
- Markdown output discipline: `## ` headers only (never `# ` — the filename owns the document title), never deeper than `### `; verbatim quotes as `> ` blockquotes; no emoji in functional copy; no horizontal rules outside the frontmatter fences; no tables; UTF-8, LF line endings, single trailing newline.

## UX & Interaction Patterns

- The vault note's rendering is intentionally plain: Obsidian owns typography and theme, so the renderer only needs to emit standard markdown (frontmatter, headings, blockquotes, wikilinks) — no plugin-specific syntax.
- A visually distinct treatment for unattributed `[[Speaker_N]]` quotes (e.g. italic or callout styling) was proposed during UX design but explicitly deferred out of this epic's scope; it was flagged as a `FrontmatterRenderer` concern for future work, not a current requirement.

## Cross-Story Dependencies

- Within the epic, stories build strictly in order: 2.1 (render) and 2.2 (filename) are consumed by 2.3 (atomic write + collision handling), which 2.4 (stage entry point) composes together with re-publish semantics. 2.4's `--reattribute` path only checks whether the original vault note still exists and copies its filename into `auricle.supersedes` — it does not depend on 2.5. Story 2.5 (schema versioning/migration-aware reader) is a separate, independent capability for future `--reattribute` work that needs to read prior speaker names back out of old frontmatter.
- Epic 2 is validated against synthetic/fixture summary JSON, not live output — the real handoff from the summarization epic's `summary.json` cache artifact into `PersistStage` is an integration point exercised later, at the pipeline validation milestone.
- Epic 2 depends on Epic 1's `Core.AtomicWriter`, `State.StateStore`, and `Orchestrator.StageRunner` primitives; no Epic 2 story reimplements them.
