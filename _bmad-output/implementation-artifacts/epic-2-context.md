# Epic 2 Context: Vault-Native Note Persistence

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Given a synthetic summary JSON, auricle must write a correctly-formatted Obsidian note into the user's vault: atomic, with a stable filename, versioned frontmatter, and never editing an existing file. This epic delivers the persist stage as a self-contained, testable contract — validated end-to-end against synthetic summarizer output rather than depending on the real summarization stage — so that an Obsidian-native note reliably appears at the configured vault path with a schema-valid, forward-readable frontmatter block. It is the vault-trust boundary: everything downstream (Attribution UX tagging, doctor diagnostics, re-run/reattribute flows) depends on this contract holding exactly.

## Stories

- Story 2.1: FrontmatterRenderer — Data to Markdown with All Schema Variants
- Story 2.2: FilenameResolver — Slug Priority Chain, Normalization, and Edge Cases
- Story 2.3: VaultWriter — Atomic Write, Path Resolution, Collision Handling
- Story 2.4: Persist Stage Entry Point — Compose Renderer + Writer + Re-publish Semantics
- Story 2.5: Frontmatter Schema Versioning + Migration-Aware Reader

## Requirements & Constraints

- auricle never re-opens an existing vault file for write; every persist is `temp file → fsync → rename`, so a process kill at any point leaves the vault either with the complete new file or no file at all — zero partial writes tolerated.
- Manual user fixes made directly in Obsidian are permanent and never contested by auricle, because auricle only ever adds new files.
- Every note has a stable structure: frontmatter block, one-paragraph summary, an Action Items section and a Decisions section (each bullet followed by a source quote), and a collapsed Transcript section.
- Speakers are rendered as Obsidian `[[wikilinks]]`, resolvable to existing or future people-notes.
- Frontmatter carries meeting time, attendees (as wikilinks), source audio path, calendar event ID when available, a tags array, a schema version, and retention policy — but excludes operational data (cache paths, timings, cost, model identifiers): that lives in SQLite, not the vault.
- Filenames are stable and predictable, derived from date + meeting title/attendees, and must avoid collisions.
- The frontmatter schema is versioned and documented; breaking changes bump the major version and require a documented migration path for existing notes.
- Vault writes must complete within 500ms for a note up to 50KB.
- Vault notes inherit standard vault file permissions; auricle never chmods existing files.
- auricle is compatible with current Obsidian (1.x) via `obsidian://` URLs; no plugin or special vault config is assumed.

## Technical Decisions

- **Frontmatter shape:** YAML frontmatter with `title`, `date`, `tags`, `attendees` (list of `"[[Wikilink]]"` strings), and an `auricle:` block holding only identity/lineage fields — `meeting_id` (ULID) and `schema_version` (plus optional `supersedes`). No operational fields ever belong in the vault; that boundary is intentional and load-bearing.
- **Four note variants** exist, each changing tags/fields: standard (calendar + attribution both succeeded); publish-anyway (`auricle/needs-attribution` tag, `Speaker_N` placeholders); calendar-enrichment-failed (`auricle/needs-calendar-enrichment` tag, generic title, empty attendees); re-published (no new tag, adds `auricle.supersedes` pointing at the original filename). Combinations (e.g. publish-anyway + calendar-failed) apply both sets of changes simultaneously.
- **Schema versioning policy:** `auricle.schema_version` is required forever and never renamed. Additive fields within a version are ignored by older readers (Postel's law) and never bump the version. Breaking changes bump the version and require the reader to keep handling every version ever shipped. The migration-aware reader (used by `--reattribute`) dispatches on version, fails fast with a clear, version-specific error on both too-old and too-new (forward-incompatible) notes.
- **Re-publish semantics:** re-publish never edits the original note. It writes a sibling file named `<original-without-ext>--rerun-<YYYY-MM-DD>.md` (double-hyphen, date suffix), with same-day repeats getting an ordinal (`--rerun-<date>-2.md`). The re-run's frontmatter adds `auricle.supersedes: "<original-filename>.md"`. `meetings.vault_note_path` always tracks the latest publish; history is reconstructible from `stage_events` but is not first-class queryable.
- **Filename convention:** `<YYYY-MM-DD>-<slug>.md`, where the date is `capture_started_at` in local time (the one deliberate local-time exception in an otherwise-UTC system). Slug is chosen by priority chain, falling through whenever a source normalizes to empty: (1) calendar event title, (2) `with-<attendee>[-and-<attendee>]` for ≤3 named attendees (self omitted), (3) `meeting-at-<HHMM>` 24h local time, (4) `meeting-<first-8-chars-of-id>` as a defensive terminal fallback. Normalization: NFKD decompose → strip non-ASCII → lowercase → collapse non-alphanumerics to single hyphens → trim → cap at 60 chars (truncate at last hyphen boundary). Same-Mac same-day collisions get a single-hyphen ordinal suffix (`-2`, `-3`) — deliberately a different suffix shape from the re-publish double-hyphen suffix, so the two cases are visually and mechanically distinct. Cross-Mac filename collisions are an accepted, low-probability, manually-recoverable trade-off (not solved by construction).
- **Vault path config** splits into two knobs: `vault_path` (the vault root; must already exist and be writable — auricle never auto-creates it, since accidentally creating someone's vault is worse than refusing to publish) and `meetings_subdir` (auricle-owned; auto-created if missing, inheriting `vault_path` permissions; fails fast if it exists as a non-directory or non-writable directory).
- **Atomic-write primitive:** a single `AtomicWriter` (temp → fsync → rename) is the only filesystem-write primitive in the codebase; a repo-level lint/grep check fails the build on any direct `Data.write`/`String.write`/`FileManager.createFile` bypass. `VaultWriter` composes on top of it, adding path validation and collision handling, and itself never opens an existing vault file for write.
- **Markdown structural discipline:** section headers use `## ` only (never `# ` — the filename owns the document title) and never go deeper than `### `; verbatim quotes use `> ` blockquote prefix; no emoji in functional copy; no horizontal rules outside the frontmatter fence; no tables; UTF-8 with LF endings and a single trailing newline.
- **Persist failure handling:** a vault write error (disk full, transient permission flap, locked target) gets one retry after 1s, then surfaces as `persist_failed` (transient, resumable via re-running the stage).

## Cross-Story Dependencies

- Builds on Epic 1's foundation: `Core/AtomicWriter`, the SQLite-backed state store, the two-transaction stage pattern, and `MeetingID` (ULID) — none of that is re-derived here.
- Stories 2.1–2.3 (renderer, filename resolver, writer) are independent leaf components; Story 2.4 composes all three plus re-publish orchestration; Story 2.5's schema-versioned reader is required by Story 2.4's `--reattribute` path.
- At runtime the persist stage consumes the summarize stage's output (Epic 3), but this epic is deliberately validated against synthetic summary JSON so its stories aren't blocked on Epic 3 landing first.
- `auricle doctor` (Epic 9) surfaces `vault_path` validation failures produced by this epic's `VaultWriter`.
