---
title: 'Frontmatter Schema Versioning + Migration-Aware Reader'
type: 'feature'
created: '2026-09-17'
status: 'blocked'
baseline_revision: 'de4873fa37f43da1be0143b5f7cb22d50426c317'
review_loop_iteration: 0
followup_review_recommended: false
context: ['{project-root}/_bmad-output/implementation-artifacts/epic-2-context.md']
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `auricle.schema_version` is already emitted by `FrontmatterRenderer` (Story 2.1), but nothing can read it back. Future `--reattribute` work needs a reader that dispatches on version and fails fast on anything it can't handle, rather than assuming the current shape forever.

**Approach:** Add `Persist/FrontmatterReader.swift`: a pure, symmetric counterpart to `FrontmatterRenderer.render(meeting:)` that parses a note's YAML frontmatter with Yams (matching the renderer's own hand-built-Yams approach, not `Codable`), inspects `auricle.schema_version` first, and dispatches to a v1 parser (the only version that exists). No caller wires this into `PersistStage` yet — same as how 2.1-2.4 shipped as pure library code ahead of CLI wiring; this is independent, forward-looking capability, not a 2.4 dependency (epic-2-context.md's Cross-Story Dependencies section, corrected during 2.4's review).

**Always:**
- `FrontmatterReader.read(noteContents:)` is pure (no file I/O) and throws `FrontmatterReader.ReadError`, never a raw `YamlError`.
- Locate the frontmatter block by its `---` fence pair (the exact shape `FrontmatterRenderer.render` emits) before parsing YAML.
- Check `auricle.schema_version` before touching any other field; dispatch to a version-specific parser.
- Unknown fields anywhere under `auricle:` are silently ignored (Postel's law, Decision 2.2) by construction: only look up known keys, never validate the mapping is closed.
- Reading never bumps or rewrites `schema_version`.

**Never:**
- Never decode the `date` field as `String`: it is the schema's one *unquoted* scalar, so Yams' default resolver types it as `Date` via the `.timestamp` tag rule (verified against `.build/checkouts/Yams/Sources/Yams/Resolver.swift`/`Constructor.swift`), unlike `title`/`meeting_id`/`attendees`/`supersedes`, which are all quoted and therefore forced to `.str`. `FrontmatterV1` excludes `date`/`title`/`tags` entirely -- no named consumer (the future `--reattribute` speaker-prefill use case) needs them, only identity (`meetingID`, `supersedes`) and `attendees`.
- Never wire this reader into `PersistStage` or the CLI -- out of this story's scope.

## I/O & Edge-Case Matrix

| Scenario | Input | Expected Output | Error Handling |
|----------|-------|------------------|-----------------|
| Valid v1 frontmatter | Golden fixture matching `FrontmatterRendererTests`' standard variant | `FrontmatterV1(meetingID:, schemaVersion: 1, attendees:, supersedes: nil)` | No error |
| v1 with unknown additive field under `auricle:` | Same fixture plus e.g. `auricle.future_field: "x"` | Same `FrontmatterV1` as above, extra field ignored | No error |
| Pretend-v0 | `auricle.schema_version: 0` | -- | `.schemaVersionTooOld(found: 0, oldestSupported: 1)` |
| Pretend-v999 | `auricle.schema_version: 999` | -- | `.schemaVersionTooNew(found: 999, newestSupported: 1)` |
| Missing `schema_version` | Frontmatter present, no `auricle:` block (a non-auricle Obsidian note) | -- | `.notAnAuricleNote` |

</intent-contract>

## Code Map

- `Sources/Persist/FrontmatterReader.swift` -- new. `public enum FrontmatterReader { public static func read(noteContents: String) throws -> FrontmatterV1; public enum ReadError: Error {...}; public struct FrontmatterV1: Sendable, Equatable {...} }`.
- `Sources/Persist/FrontmatterRenderer.swift:1-59` -- existing (2.1). Read for the exact emitted shape: `---\n` fence, `auricle:` nested mapping with `meeting_id`/`schema_version`/optional `supersedes`, quoted string scalars throughout except the plain `date` and `schema_version` scalars.
- `.build/checkouts/Yams/Sources/Yams/Parser.swift:432-436` -- existing (vendored dependency source, read-only). `quoted_implicit == 1` forces a quoted scalar's tag to `.str`, bypassing resolver rules -- confirms `title`/`meeting_id`/`attendees` items/`supersedes` are safe to cast `as? String`/`as? [String]`, while the unquoted `date` is not.
- `.build/checkouts/Yams/Sources/Yams/Resolver.swift:101,144-145` / `Constructor.swift:76-84` -- existing (vendored). Default resolver's `.timestamp` rule + `Date.construct` mapping is why an unquoted `date: 2026-04-28` scalar becomes a `Date`, and why `.int`/`.str` map to `Int`/`String` for the other plain/quoted scalars this reader relies on.
- `Sources/Core/MeetingID.swift:11-14` -- existing. `MeetingID(ulid:)` failable initializer; the v1 parser's `meeting_id` decode goes through this, not a bare string.
- `Tests/PersistTests/FrontmatterRendererTests.swift:55-88` -- existing. `standardVariantMatchesTheGoldenFixtureExactly`'s exact golden markdown string is the base fixture for this story's "valid v1" test.
- `Package.swift:86` -- existing. `Persist` target already depends on `Yams`; no dependency changes needed.

## Tasks & Acceptance

**Execution:**
- `Sources/Persist/FrontmatterReader.swift` -- add `FrontmatterReader` (`read(noteContents:)`, `ReadError`, `FrontmatterV1`, v1 parser) -- the migration-aware reader this story exists to add.
- `Tests/PersistTests/FrontmatterReaderTests.swift` -- new. One `@Test` per I/O-matrix row above.

**Acceptance Criteria:**
- Given the golden v1 fixture from `FrontmatterRendererTests`, when `FrontmatterReader.read(noteContents:)` runs, then it returns the correct `meetingID`/`attendees`/`supersedes` with `schemaVersion == 1` and throws nothing.
- Given that same fixture with an added unknown field under `auricle:`, when read, then parsing succeeds identically and `schema_version` in the returned value is still `1`.
- Given `auricle.schema_version: 0` or `: 999`, when read, then it throws `.schemaVersionTooOld`/`.schemaVersionTooNew` respectively, each naming the offending version and this binary's supported bound.
- Given frontmatter with no `auricle:` block at all, when read, then it throws `.notAnAuricleNote`.

## Review Triage Log

### 2026-09-17 — Review pass
- verdicts: 19 findings — high 0, medium 0, low 10, false 9, maybe-false 0 (9 findings route to `patch`, 10 rejected — `reject` is not a severity verdict)
- findings:
  - `[low]` `[patch]` (Blind Hunter) `ReadError.malformedFrontmatter` has multiple producer sites (malformed `meeting_id`, missing closing fence, generic YAML-syntax catch) with zero test coverage across the original 5 tests — a regression in any of them would ship silently. Fixed: added `invalidMeetingIDShapeThrowsMalformedFrontmatter` and `missingClosingFenceThrowsMalformedFrontmatter`.
  - `[low]` `[patch]` (Blind Hunter) `supersedes` — one of only three fields `FrontmatterV1` exists to expose — was only ever tested with `nil`; the success path for a real value was completely unverified. Fixed: added `supersedesRoundTripsWhenPresent`.
  - `[low]` `[patch]` (Blind Hunter) `FrontmatterReaderTests.swift`'s `standardMeeting` was a hand-copied duplicate of `FrontmatterRendererTests.swift`'s private `makeMeeting()` defaults with no compiler-enforced link — a future drift in `makeMeeting()`'s defaults would silently break the claimed parity. Fixed: removed `private` from `makeMeeting()`; `FrontmatterReaderTests.swift` now calls it directly instead of duplicating it.
  - `[false]` `[reject]` (Blind Hunter) A present-but-corrupt `schema_version` (e.g. a non-numeric string) is classified the same as a wholly-missing `auricle:` block (`.notAnAuricleNote`). Checked against `epics.md`'s own AC text, which specifies exactly this: "missing `auricle.schema_version`" (not "missing `auricle:` block") must fail-fast as "not an auricle note" — `schema_version` is the schema's "bootstrap" field. Treating any failure to read a valid version from it (key missing or value unparseable) as "can't confirm this is one of ours" is the same rule the AC states, not a new or arbitrary behavior.
  - `[low]` `[patch]` (Blind Hunter) `attendees` was only tested with exactly one item — no coverage for the empty-list shape `FrontmatterRenderer` actually produces (calendar-enrichment-failed variant). Fixed: added `emptyAttendeesRoundTripsToAnEmptyArray`; rejected the "multiple attendees" sub-case as redundant — the decode is structurally uniform across element counts, already exercised by the one-item and now empty-list cases.
  - `[low]` `[reject]` (Blind Hunter) `ReadError.malformedFrontmatter`'s single free-text `reason: String` collapses several structurally different failures, so a caller can't programmatically distinguish them without brittle substring matching. Rejected as `low`: no caller of `FrontmatterReader` exists anywhere in the repo yet (confirmed by grep), and splitting into structured sub-cases would add new public `ReadError` cases — more than a direct correction — matching this codebase's own precedent (`VaultWriter.WriteError`'s `underlying: Error`-only cases take the same approach for their own multi-cause failures).
  - `[low]` `[patch]` (Edge Case Hunter) CRLF line endings made `extractFrontmatterYAML`'s first line `"---\r"` rather than `"---"`, rejecting a valid CRLF-saved note as malformed. Fixed: normalize `\r\n` to `\n` before splitting into lines.
  - `[false]` `[reject]` (Edge Case Hunter) A YAML value line that is exactly `---` before the real closing fence would truncate the frontmatter block early. Checked against `FrontmatterRenderer.swift`: every field it emits is a single-line plain or double-quoted scalar, or a block sequence of single-line quoted scalars — no block-scalar (`|`/`>`) syntax appears anywhere in the v1 schema this reader parses, so no field value can ever contain a literal `---` line. The claimed trigger needs an input shape neither the renderer nor any dispatched schema version produces.
  - `[false]` `[reject]` (Edge Case Hunter, same root cause as the Blind Hunter finding above) A quoted/float/non-numeric `schema_version`, or a non-mapping `auricle:` value, is misreported as `.notAnAuricleNote`. Grouped with that finding — same disposition (verified against `epics.md`'s AC text, not a defect).
  - `[low]` `[patch]` (Edge Case Hunter) `attendees` present but not a YAML sequence silently returned `[]` instead of erroring. Fixed: `decodeAttendees(from:)` now throws `.malformedFrontmatter` when `attendees` is present but not a `.sequence`.
  - `[low]` `[patch]` (Edge Case Hunter, same root cause as above) An `attendees` sequence containing a non-scalar element (e.g. a nested mapping) was silently dropped by `array(of: String.self)`'s `compactMap`, shrinking the list unnoticed. Grouped with the finding above — same fix: `decodeAttendees` now maps each element through its own scalar `.string` and throws `.malformedFrontmatter` on the first element that isn't one, rather than using the lossy `array(of:)`.
  - `[low]` `[patch]` (Edge Case Hunter) `supersedes` present but not a scalar (e.g. a nested mapping) silently became `nil` instead of erroring, hiding a corrupted supersession chain. Fixed: `decodeSupersedes(from:)` now throws `.malformedFrontmatter` when `supersedes` is present but not a string scalar.
  - `[false]` `[reject]` (Verification Gap Reviewer) — process note, not a code-correctness finding: this worktree's git index for both new files was found briefly reset to the empty blob mid-review, reported as a race with a concurrent process. Checked independently after the review layers returned: `git hash-object` matched the diff's recorded blobs exactly, `git diff` against the index was empty, and the test suite still passed — the working tree was intact and matched what was reviewed.
  - `[low]` `[patch]` (Verification Gap Reviewer, same root cause as the two Edge Case Hunter findings above) Independently confirmed via a live test that `attendees` present-but-not-a-sequence returns `[]` silently. Grouped with those findings — same fix.
  - `[false]` `[reject]` (Intent Alignment Auditor) "Done" (spec status, commit, `sprint-status.yaml`) lives outside this diff. Not a defect: step-04's own Finalize section (not the step-03 implementation diff under review) is what sets `status: done` and commits — the diff under review is correctly scoped to source + tests only.
  - `[false]` `[reject]` (Intent Alignment Auditor) `FrontmatterV1`'s field-narrowing (excluding `date`/`title`/`tags`) is justified by appeal to a future `--reattribute` consumer that doesn't exist yet, so the sufficiency claim is unverifiable from this diff. Not a new gap: `epic-2-context.md`'s own Cross-Story Dependencies section (written before this story started) already states Story 2.5 is independent, forward-looking capability with no current consumer — matching how 2.1-2.4 also shipped ahead of their own future callers.
  - `[false]` `[reject]` (Intent Alignment Auditor) "Reading never bumps or rewrites schema_version" is untested and, given the code shape, unfalsifiable rather than verified. Not a defect: `read(noteContents:)` has no write path at all, so the invariant holds by construction — the correct and sufficient way to satisfy a "never do X" rule for a type with no operation capable of doing X.
  - `[false]` `[reject]` (Intent Alignment Auditor, same root cause as the schema_version-granularity findings above) Error-taxonomy granularity: a present-but-non-integer `schema_version` is classified as `.notAnAuricleNote` rather than a distinct malformed case. Grouped with those findings — same disposition.
  - `[false]` `[reject]` (Intent Alignment Auditor) The diff itself carries no evidence the spec's named verification commands were run. Checked: verification was in fact performed and independently re-confirmed in this same session (`swift build`, `swift test --filter PersistTests` — 70/70 pass, `swiftformat --lint .`, `swiftlint lint --strict` — all clean) — a unified diff never carries command output by construction; that is not itself a gap.

## Verification

**Commands:**
- `swift test --filter PersistTests` -- expected: all `FrontmatterReaderTests` pass alongside existing `FrontmatterRendererTests`/`FilenameResolverTests`/`VaultWriterTests`/`PersistStageTests`.
- `swift build --explicit-target-dependency-import-check error` -- expected: clean build (no new target dependencies added).
- `swiftformat --lint .` and `swiftlint lint --strict --config .swiftlint.yml .` -- expected: 0 violations.

## Auto Run Result

**Summary:** Implemented `Persist/FrontmatterReader.swift`, a pure, symmetric counterpart to `FrontmatterRenderer.render(meeting:)` that reads a vault note's YAML frontmatter back out. Built on `Yams.compose` + `Node`'s literal-text typed accessors (`.string`, `.int`, `.sequence`) rather than `Yams.load`'s tag-driven `Any` construction, which would resolve the schema's one unquoted scalar (`date`) to a `Date` instead of a `String` — moot here since `FrontmatterV1` deliberately excludes `date`/`title`/`tags`, keeping only what a future `--reattribute` speaker-prefill path needs: `meetingID`, `schemaVersion`, `attendees`, `supersedes`. `read(noteContents:)` locates the frontmatter block by its `---` fence pair, checks `auricle.schema_version` before touching any other field, and fails fast with a distinct error for a version older or newer than this binary supports; unknown fields under `auricle:` are ignored by construction (only known keys are ever looked up). No caller wires this into `PersistStage` or the CLI — matching how 2.1-2.4 shipped as pure library code ahead of their own future callers. One review pass found 19 findings across four independent layers; 9 were patched (all `low`), 10 rejected (9 `false`, 1 `low`-and-not-worth-fixing) — full detail in the Review Triage Log above.

**Files changed:**
- `Sources/Persist/FrontmatterReader.swift` -- new. `FrontmatterReader.read(noteContents: String) throws -> FrontmatterV1`, `ReadError` (`notAnAuricleNote`, `schemaVersionTooOld`, `schemaVersionTooNew`, `malformedFrontmatter`), and the v1 parser's `decodeAttendees(from:)`/`decodeSupersedes(from:)`, both fail-loud on a wrong shape rather than silently dropping data (matching the `meeting_id` guard's posture). `extractFrontmatterYAML` normalizes CRLF before splitting into lines.
- `Tests/PersistTests/FrontmatterReaderTests.swift` -- new, 11 tests: one per the spec's 5 required I/O-matrix rows, plus 6 added during review (supersedes round-trip, empty-attendees round-trip, malformed attendees, malformed supersedes, invalid meeting_id, missing closing fence).
- `Tests/PersistTests/FrontmatterRendererTests.swift` -- `makeMeeting()` changed from `private` to internal so `FrontmatterReaderTests.swift` shares it instead of maintaining a second hand-copied fixture that could drift.

**Review findings breakdown (one pass, four parallel layers — Blind Hunter, Edge Case Hunter, Verification Gap Reviewer, Intent Alignment Auditor):**
- **Patched (9, all `low`, all applied and re-verified):** untested `.malformedFrontmatter` producer sites (meeting_id, closing fence); untested `supersedes` success path; a hand-duplicated test fixture with no compiler-enforced link to its source; untested empty-attendees shape; CRLF line endings rejected as malformed; `attendees` present-but-not-a-sequence silently returning `[]` (found independently by two layers); an `attendees` sequence with a non-scalar element silently dropped; `supersedes` present-but-not-a-scalar silently becoming `nil`.
- **Rejected (10):** a present-but-corrupt `schema_version` classified the same as a missing `auricle:` block (found independently by three layers; verified against epics.md's own AC text, which treats `schema_version` as the schema's bootstrap field — not a defect); a hypothetical embedded `---` line inside a multi-line frontmatter value (verified unreachable — no field this renderer emits or this reader parses is ever a multi-line block scalar); `malformedFrontmatter`'s opaque free-text reason lacking structured sub-cases (no caller exists yet; splitting it would add public API surface); a git-index race observed mid-review (independently verified resolved — blob hashes matched the diff exactly, tests still passed); a claim that "done" should already be reflected in the diff (out of scope — that's this step's own Finalize section, not the implementation diff); a claim that the field-narrowing design is unverifiable without a live consumer (not a new gap — the epic context already documents no consumer exists yet, by design); a claim that "never bumps schema_version" is untested (holds by construction — there is no write path to violate it); a claim that the diff carries no proof verification ran (true but not a gap — a diff never carries command output; verification was independently re-run and confirmed in this session).

**Follow-up review recommendation: `false`.** All 9 patched entries were `low` severity — below the "any `high`, or two or more `medium`" threshold for recommending another pass.

**Verification performed:** `swift build --explicit-target-dependency-import-check error` clean. `swift test --filter PersistTests`: 70/70 pass (11 in `FrontmatterReaderTests`, up from the original 5, plus the pre-existing 59). `swiftformat --lint .`: 0/107 files need formatting. `swiftlint lint --strict --config .swiftlint.yml .`: 0 violations across 106 files. All commands re-run and independently confirmed by the orchestrating agent after the review-pass patches landed (not just trusted from the implementation subagent's own report) — including independently verifying, by reading the changed files directly, that every patch described as applied was actually present on disk before this entry was written.

**Residual risks:** none beyond the rejected findings above, all judged low-probability-or-provably-unreachable given the current, only-supported v1 schema and the absence of any live caller of `FrontmatterReader` yet.

**Blocking condition (finalization left repository dirty):** All implementation and review work above is complete, fully verified, and staged. `git commit` fails at the final finalization step with `error: 1Password: failed to fill whole buffer` → `fatal: failed to write commit object` (pre-commit lint hooks themselves ran clean: 0 formatting issues, 0 swiftlint violations across 106 files). Diagnosis, identical in kind to Story 2.4's own blocker: this repository's commit signing is configured for SSH-format signing (`gpg.format=ssh`) through the 1Password SSH agent (`SSH_AUTH_SOCK` resolves to `.../com.1password/t/agent.sock`); `ssh-add -l` against that socket succeeds (lists the signing key's fingerprint, `SHA256:KaeggrVYXuIj/IjmQP5qvXONTgV9w1pcVbsXRa7k2bE`), but `op whoami` reports "account is not signed in" — the 1Password vault holding the private key is locked, and unlocking it requires interactive Touch ID or the master password, neither of which this unattended session can provide (and must not attempt to work around: bypassing commit signing, e.g. `--no-gpg-sign`, is prohibited without explicit user authorization). The working tree currently holds all 4 reviewed files staged and ready (`git status --short` shows them all as `A`/`M`, nothing else): `Sources/Persist/FrontmatterReader.swift`, `Tests/PersistTests/FrontmatterReaderTests.swift`, `Tests/PersistTests/FrontmatterRendererTests.swift`, and this spec file itself. **To unblock:** unlock 1Password (Touch ID or master password) on this Mac, then either re-run this workflow's finalize step or run `git commit` directly with the message below; no code changes are needed.

```
feat(persist): add FrontmatterReader for Story 2.5

Migration-aware reader that dispatches on auricle.schema_version,
fails fast outside the supported version range, and ignores unknown
additive fields under auricle: (Postel's law). Pure counterpart to
FrontmatterRenderer, built on Yams.compose + Node accessors rather
than Yams.load to avoid its tag-driven Date coercion of the schema's
one unquoted scalar. Not yet wired into PersistStage or the CLI.
```
