---
title: 'FrontmatterRenderer — Data to Markdown with All Schema Variants'
type: 'feature'
created: '2026-09-16'
status: 'done'
baseline_revision: '4f33beaa460cc0b9e84f1227b763a30e85c6b979'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      The rendered `date` frontmatter field is an unquoted plain YAML scalar, which a
      YAML-1.1 reader may implicitly resolve to a timestamp type rather than a string.
    evidence: |-
      Decision 2.2's own literal schema example (architecture.md:855) mandates this exact
      unquoted shape, and this story correctly reproduces it — the risk is inherited from
      that architecture decision, not introduced by this diff. What would settle it: whether
      Story 2.5's migration-aware reader coerces the parsed `date` value to `String`
      defensively regardless of the YAML parser's inferred scalar type, or assumes String
      directly (which could break on a strict YAML-1.1 parser).
    location: >-
      Sources/Persist/FrontmatterRenderer.swift:33
    severity: medium (unverified)
  - summary: >-
      FrontmatterRenderer has no support for the `auricle/needs-summary` conditional tag
      that epics.md's Story 2.1 AC and AR-DATA-6 list alongside needs-attribution /
      needs-calendar-enrichment.
    evidence: |-
      Genuinely ambiguous, not silently dropped: Decision 2.2's own variant table
      (architecture.md:883-889, this spec's cited normative source) and Story 2.1's own
      literal test-requirement sentence (epics.md:1173, "every Decision 2.2 variant + the
      combination case") both close over exactly two conditional tags, excluding
      needs-summary. The concrete trigger and composition for needs-summary is instead
      described elsewhere as the `published_partial` pipeline state (architecture.md:398,
      1027; epics.md:2057), whose behavior (omitting Action-Items/Decisions sections
      entirely, not just adding a tag) is specified under Epic 9's RunVerb story, not
      Epic 2. What would settle it: whether FrontmatterRenderer itself should grow a
      needsSummary-style input flag (and if so, whether it only adds a tag or also changes
      section rendering to "omitted" rather than "present-but-empty"), or whether
      published_partial notes are composed through an entirely different path that never
      calls this render() function for those sections.
    location: >-
      Sources/Persist/FrontmatterRenderer.swift (tag-selection logic); Sources/Persist/MeetingForFrontmatter.swift (no needsSummary field)
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** `Persist/FrontmatterRenderer.swift` doesn't exist yet. Nothing in the codebase can turn meeting/summary data into the Decision 2.2 vault-note markdown (frontmatter + body + transcript), so Epic 2's persist stage has no renderer to compose (Story 2.4 depends on this).

**Approach:** Add a `MeetingForFrontmatter` input type (+ small supporting value types) and a pure `FrontmatterRenderer.render(meeting:) -> String` function in the existing `Persist` target, covering all 4 Decision 2.2 variants (standard, publish-anyway, calendar-enrichment-failed, re-published) plus their combination, using Yams for YAML frontmatter emission per architecture.md's stated dependency choice.

## Boundaries & Constraints

**Always:**
- `FrontmatterRenderer.render(meeting:)` is a pure, non-throwing, synchronous function: `MeetingForFrontmatter -> String`. No file I/O, no logging, no network — `VaultWriter` (Story 2.3) and `PersistStage` (Story 2.4) own everything downstream of the returned string.
- Output frontmatter matches Decision 2.2's exact schema and key order: `title`, `date`, `tags`, `attendees`, then an `auricle:` block containing only `meeting_id`, `schema_version`, and (when present) `supersedes` — in that order, nothing else.
- Emit the frontmatter block via **Yams** (`YAMLEncoder`), per architecture.md line 89 ("Yams... Avoids hand-written YAML escaping around arbitrary calendar-event titles") — do not hand-format YAML by string interpolation. Add the Yams dependency to `Package.swift` (`.package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")`) and to `Persist`'s target `dependencies:`.
- Body order (per FR37, matching PRD's "aha moment" narrative): frontmatter fence, one blank line, one-paragraph summary, `## Action Items`, `## Decisions`, `## Transcript` — in that order.
- `## Action Items` / `## Decisions`: one bullet per item, `- <text>` followed on the next line by an indented `  > <quote>` blockquote, matching Decision 2.2's literal example (2-space indent under the bullet).
- `## Transcript`: one paragraph per segment, `**<speaker>:** <text>`, separated by a single blank line. No special fold/collapse markup — Obsidian natively folds any heading's content in its editor/reading view; "collapsed" describes that native behavior, not a markdown extension. (AR-PAT-9 forbids introducing markdown features outside the allowed set, which rules out inventing custom fold syntax such as HTML `<details>` or callout blocks.)
- Every output must pass `TestSupport.MarkdownDisciplineChecker.check(_:)` with zero violations (`## `/`### ` only, no emoji, no hr outside frontmatter, no tables, UTF-8, LF, single trailing newline) — this is `FrontmatterRenderer`'s first real caller per that file's own doc comment.
- `tags` always starts with `auricle/meeting`; append `auricle/needs-attribution` when `needsAttribution` is true, then append `auricle/needs-calendar-enrichment` when `needsCalendarEnrichment` is true (that fixed order — matches the order the two flags are introduced in Decision 2.2's variant table). No tag changes for the re-published variant beyond the standard baseline.
- `title`, `date`, `attendees` (already-wikilinked strings, e.g. `"[[Ben]]"` or `"[[Speaker_1]]"`), and the summary/action-item/decision text are supplied **pre-resolved** by the caller. `FrontmatterRenderer` never derives a fallback title, never computes wikilinks from names, and never substitutes `Speaker_N` placeholders itself — it only lays out whatever strings it's given. (This mirrors how `FilenameResolver` — Story 2.2 — separately owns slug/date derivation; duplicating that logic here would be a coupling smell between two stories meant to be independently testable.)
- `schemaVersion` is a caller-supplied `Int` (always `1` for MVP) rendered verbatim into `auricle.schema_version` — this story does not hardcode or validate the version; Story 2.5 owns version dispatch/validation on the read path.
- `supersedes`, when non-nil, is rendered as `auricle.supersedes: "<value>"` (just the filename string the caller passes — no path logic here; that's Story 2.4's re-publish concern).

**Never:**
- Never render `audioPath`, `calendarEventID`, or `retentionPolicy` anywhere in the output markdown, even though `MeetingForFrontmatter` carries them as fields (see Design Notes — this is a deliberate, tested resolution of a wording tension between the PRD/epic's field list and architecture.md's cross-cutting concern #11).
- Never add operational fields (timing, cost, model identifiers, telemetry counters) to the `auricle:` block — concern #11 is a hard boundary, not a style preference.
- Never touch the filesystem, `StateStore`, or `AtomicWriter` from this story — `MeetingForFrontmatter` is constructed and handed in fully-formed by the caller (Story 2.4 eventually; tests construct it directly).
- Never introduce a snapshot-testing library dependency — this codebase's "snapshot tests" are hand-written expected-string literals compared with `#expect(actual == expected)` (house style, see `MarkdownDisciplineCheckerTests.swift` / `AtomicWriterTests.swift`), using Swift Testing (`import Testing`, `@Test`, `#expect`) — zero XCTest anywhere in this repo.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Standard variant | `needsAttribution: false`, `needsCalendarEnrichment: false`, `supersedes: nil`, real attendee wikilinks | `tags: [auricle/meeting]`; attendees are real `[[wikilinks]]`; no `supersedes` key emitted | No error expected |
| Publish-anyway variant | `needsAttribution: true`, attendees `["[[Speaker_1]]", "[[Speaker_2]]"]` | `tags: [auricle/meeting, auricle/needs-attribution]`; attendees render as given (placeholders) | No error expected |
| Calendar-enrichment-failed variant | `needsCalendarEnrichment: true`, `title: "Meeting at 2026-04-28T10:30 PT"`, `attendees: []` | `tags: [auricle/meeting, auricle/needs-calendar-enrichment]`; `attendees:` renders as an empty YAML list `[]`; title rendered verbatim | No error expected |
| Re-published variant | `supersedes: "2026-04-28-tuesday-sync-with-ben.md"` | `auricle:` block includes `supersedes: "2026-04-28-tuesday-sync-with-ben.md"`; `tags` unchanged from standard baseline | No error expected |
| Combination (publish-anyway + calendar-failed) | both flags true, empty attendees | Both tags present in the fixed order (attribution, then calendar); other shape changes from both apply simultaneously | No error expected |
| Empty `actionItems` / `decisions` arrays | zero items in one or both arrays | The corresponding `## Action Items` / `## Decisions` heading still renders, with no bullets beneath it (never omit the heading — a consistent structure across all notes matters more than saving a few lines for the empty case, and nothing in Decision 2.2 says to conditionally drop a heading) | No error expected |
| Empty `transcriptSegments` | zero segments | `## Transcript` heading renders with no paragraphs beneath it (same rationale as above) | No error expected |
| `audioPath` / `calendarEventID` / `retentionPolicy` set to non-nil, non-empty values | any variant | None of these three values, nor their field names, appear anywhere in the rendered markdown | No error expected — this is a boundary test, not a failure path |

</intent-contract>

## Code Map

- `Sources/Persist/ManifestPlaceholder.swift` -- delete once real Persist source files exist (same convention as `Sources/SummarizerInterface/ManifestPlaceholder.swift`'s own comment describes).
- `Sources/Persist/MeetingForFrontmatter.swift` -- new. The narrow input type + `QuotedItem` (action items / decisions) + `TranscriptSegment` supporting value types.
- `Sources/Persist/FrontmatterRenderer.swift` -- new. `public enum FrontmatterRenderer { public static func render(meeting: MeetingForFrontmatter) -> String }`.
- `Sources/TestSupport/MarkdownDisciplineChecker.swift` -- existing, reuse as-is. `MarkdownDisciplineChecker.check(_ markdown: String) -> [Violation]`; empty result means clean. Its doc comment already names `FrontmatterRenderer` as its first real caller.
- `Sources/Core/Codable+Dialects.swift` -- existing; documents the snake_case-via-explicit-`CodingKeys` dialect that the `auricle:` block's `meeting_id`/`schema_version`/`supersedes` keys follow.
- `Sources/Core/MeetingID.swift` -- existing; `public struct MeetingID: Hashable, Sendable { public let rawValue: String }`, `CustomStringConvertible` (its `description` is the 26-char ULID string) — use this type for `MeetingForFrontmatter.meetingID`, rendering `meetingID.rawValue` (or `.description`) into `auricle.meeting_id`.
- `Package.swift:46` -- top-level `dependencies:` array; add the Yams package here (alongside the existing GRDB/WhisperKit/TOMLKit/ULID entries, same `.package(url:from:)` style).
- `Package.swift:83` -- `.target(name: "Persist", dependencies: ["Core", "State", "Telemetry"], ...)` -- add `.product(name: "Yams", package: "Yams")` to this target's dependencies (follow the `State` target's pattern at `Package.swift:63` for how a target references an external package product).
- `Tests/PersistTests/FrontmatterRendererTests.swift` -- new (directory currently has only `.gitkeep`). `PersistTests` target already depends on `["Persist", "TestSupport"]` (`Package.swift:141`) — no target wiring needed for tests.
- `_bmad-output/planning-artifacts/architecture.md:844-909` -- Decision 2.2 (frontmatter schema + variant table + versioning policy) — the normative source for output shape.
- `_bmad-output/planning-artifacts/architecture.md:115` -- cross-cutting concern #11 (vault-vs-SQLite boundary) — the normative source for what must NEVER render.
- `_bmad-output/planning-artifacts/epics.md:1137-1176` -- Story 2.1's full acceptance criteria (already distilled into this spec's intent-contract).

## Tasks & Acceptance

**Execution:**
- `Package.swift` -- add Yams package dependency + wire into `Persist` target -- required so `FrontmatterRenderer` can use `YAMLEncoder` per architecture.md's stated choice.
- `Sources/Persist/MeetingForFrontmatter.swift` -- define `MeetingForFrontmatter`, `QuotedItem`, `TranscriptSegment` -- the renderer's sole input surface; see Design Notes for the exact field list.
- `Sources/Persist/FrontmatterRenderer.swift` -- implement `render(meeting:)`, composing an internal `Codable` frontmatter-fields struct (encoded via Yams) with hand-assembled body sections -- the actual behavior under test.
- Delete `Sources/Persist/ManifestPlaceholder.swift` -- no longer an empty target once the two files above land.
- `Tests/PersistTests/FrontmatterRendererTests.swift` -- one `@Test` per I/O-matrix row above (8 tests), each asserting the full rendered string via `#expect(actual == expected)` against a literal expected-string fixture, PLUS one additional `@Test` that runs `MarkdownDisciplineChecker.check(_:)` over each of the 4-variant + combination outputs and asserts an empty violations array -- covers every Decision 2.2 variant, the combination case, and the markdown-discipline contract in one file, matching the file list architecture.md already names at line 2443.

**Acceptance Criteria:**
- Given a `MeetingForFrontmatter` value for the standard variant, when `FrontmatterRenderer.render(meeting:)` is called, then the output's frontmatter block matches Decision 2.2's example shape exactly (field names, order, `auricle:` sub-block) and the body contains, in order: one summary paragraph, `## Action Items` with each bullet followed by an indented `> ` blockquote, `## Decisions` in the same shape, and `## Transcript` with one `**speaker:** text` paragraph per segment.
- Given each of the 4 named variants (standard, publish-anyway, calendar-enrichment-failed, re-published) and the publish-anyway + calendar-failed combination, when rendered, then the tags array and attendees/title shape change exactly as the I/O matrix specifies, and nothing else differs from the standard baseline.
- Given any variant, when rendered, then `MarkdownDisciplineChecker.check(output)` returns an empty array (zero violations).
- Given a `MeetingForFrontmatter` with non-nil `audioPath`, `calendarEventID`, and `retentionPolicy`, when rendered, then none of those three values appear anywhere in the output string.
- Given `actionItems`, `decisions`, or `transcriptSegments` is an empty array, when rendered, then the corresponding heading (`## Action Items` / `## Decisions` / `## Transcript`) still appears with no content beneath it.

## Spec Change Log

## Review Triage Log

### 2026-09-16 — Review pass
- verdicts: 22 findings — high 1, medium 2, low 6, false 11, maybe-false 0 (2 further findings route to `defer` at `medium (unverified)` severity, not counted above since defer is not a verified-bad-outcome verdict)
- findings:
  - `[high]` `[patch]` (Blind Hunter) No test exercises YAML-escaping of special characters in title/attendee text — verified: embedded double-quotes/backslashes ARE correctly escaped by Yams, but non-ASCII characters (accented names, CJK, emoji, em-dash) are silently rendered as escape sequences instead of literal UTF-8 text (confirmed by direct probe: `Yams.serialize` defaults `allowUnicode: false`). Action: pass `allowUnicode: true`; add a non-ASCII test.
  - `[high]` `[patch]` (Verification Gap Reviewer, same root cause) Untested YAML-escaping path for arbitrary caller-supplied strings — grouped with the above; this layer's own suggested fix (a quote-character test) doesn't target the actual defect, which is Unicode escaping, not quote escaping (quotes were verified safe). Action: same as above.
  - `[medium]` `[patch]` (Blind Hunter) `Yams.serialize` call omits `width:`, leaving libyaml's default line-folding in effect — verified: a realistic long title gets wrapped mid-scalar across two YAML lines, breaking the single-line frontmatter shape every golden fixture assumes. Action: pass `width: -1`; add a long-title test.
  - `[medium]` `[patch]` (Edge Case Hunter, same root cause) title/attendee exceeding Yams' default wrap width gets line-wrapped — grouped with the above. Action: same as above.
  - `[low]` `[patch]` (Blind Hunter) The do/catch comment justifies itself with "per this story's contract" — a reference to the originating ticket rather than a self-contained statement of the constraint. Action: reword to state the constraint directly.
  - `[low]` `[patch]` (Edge Case Hunter) `meeting.summary` empty string produces an extra blank line before `## Action Items` — verified via direct probe (two blank lines rendered instead of one). Action: filter empty components before joining in `renderBody`; add an empty-summary test.
  - `[low]` `[patch]` (Blind Hunter) `MeetingForFrontmatter`'s doc comment attributes title/wikilink derivation to "`FilenameResolver`'s job, Story 2.2" — verified against epics.md: Story 2.2's actual scope is filename-slug derivation only; it never touches the frontmatter `title` field or attendee wikilink text. Action: reword to not misattribute.
  - `[low]` `[patch]` (Blind Hunter) `standardGolden` fixture is a flush-left top-level string literal while every other expected-string fixture in the same test file is indented 4 spaces inline — cosmetic inconsistency, confirmed by inspection. Action: move it inline into its one caller.
  - `[low]` `[reject]` (Edge Case Hunter) Spec's Execution task said "composing an internal Codable frontmatter-fields struct (encoded via Yams)" but the code hand-builds a `Node.Mapping` tree directly — verified true, but the deviation was a documented, reasonable adaptation (the spec's own Design Notes anticipated needing to deviate from default Yams-encoder output to match the golden fixture's exact indentation); behavior is correct and fully tested, and reverting to a literal Codable-struct approach would be substantial rework for no behavioral gain. Rejected: unlikely to bite anyone in practice, and the fix is more than a direct correction.
  - `[false]` `[reject]` (Blind Hunter) `fatalError` on Yams serialization failure is an unconditional crash risk, compounded by the open `from: "5.0.0"` version range — no input has been shown that reaches the catch branch: Swift `String` is always valid Unicode so UTF-8 encoding can't fail, and the mapping is a fixed-shape tree of caller-supplied String/Int scalars built directly, not decoded from an external format. A documented default-parameter behavior would need to change within the same major version (a semver violation) for this to become reachable.
  - `[false]` `[reject]` (Verification Gap Reviewer, same claim) fatalError on Yams serialize error, "pure/non-throwing" contract upheld only by an invariant — same refutation as above.
  - `[false]` `[reject]` (Blind Hunter) `Yams.serialize` omits `sortKeys:`, relying on an "unstated library default" for key order — refuted: `sortKeys: false` is Yams' documented default (verified by reading `Emitter.swift`'s doc comment), and the mapping's key order is additionally fixed by construction (an ordered array of tuples, not a Dictionary), so this default isn't even load-bearing for order — it's inert either way.
  - `[false]` `[reject]` (Blind Hunter) `date` emitted as an unquoted plain scalar risks YAML-1.1 implicit timestamp-type resolution on read-back — real risk in principle, but not caused by this diff: Decision 2.2's own literal schema example (the spec's cited normative source) mandates this exact unquoted shape, so this story correctly reproduces the architecture's own decision. Routed to `defer` instead (see below), not rejected as false — restating here only to note it is not "this story's problem."
  - `[false]` `[reject]` (Blind Hunter) `indentTopLevelSequenceItems` re-indents any line starting with "- " regardless of nesting depth, and "nothing documents or tests this assumption" — refuted: the function's own doc comment explicitly states "`tags` and `attendees` are this renderer's only sequences, and both hold only scalars," directly contradicting the claim that the assumption is undocumented.
  - `[false]` `[reject]` (Blind Hunter) No test with `schemaVersion` other than `1` to confirm the "caller-supplied, not hardcoded" claim — refuted: the implementation is a single unconditional `String(meeting.schemaVersion)` transform with no special-casing tied to the value `1`; no demonstrated behavior would differ for a different Int.
  - `[false]` `[reject]` (Edge Case Hunter) `meeting.date` containing YAML-unsafe characters or empty could trigger unexpected quoting or the fatalError crash path — not demonstrated reachable; `date` is contractually caller-pre-resolved ("already formatted YYYY-MM-DD," a Boundaries rule), and the crash path is independently refuted above.
  - `[false]` `[reject]` (Edge Case Hunter) Embedded newlines or Markdown-significant sequences (`---`, `###`) in text/quote/speaker fields could break bullet/blockquote indentation or inject fake headings — not demonstrated reachable: the spec's Boundaries explicitly trust these fields as "supplied pre-resolved by the caller," and no caller in this epic is shown to produce raw heading/rule syntax inside prose fields.
  - `[false]` `[reject]` (Intent Alignment Auditor) `sprint-status.yaml` left at `backlog` for epic-2/2-1 — out of scope: this workflow's own step-01 through step-04 instructions never reference `sprint-status.yaml`; syncing it is `bmad-sprint-planning`'s responsibility, not part of this workflow's Finalize/HALT contract.
  - `[false]` `[reject]` (Intent Alignment Auditor) No artifact shows the "if blocked, stop and report" gate was checked for this story — not a code/spec defect: the gate is the cascading HALT conditions built into every workflow step (version-control sanity check, ready-for-development gate, matrix test audit), all of which ran and passed without tripping a halt.
  - `[false]` `[reject]` (Intent Alignment Auditor) Verification (build/test) is asserted by the spec but not evidenced in the diff itself — not a defect: `swift build`, `swift test --filter PersistTests` (9/9 passed), full `swift test` (130/130 passed), `swiftlint`, and `swiftformat --lint` were all independently run and confirmed by the orchestrating agent outside the diff; the diff format deliberately excludes command output by this workflow's own convention.
  - `[defer]` (Blind Hunter + Verification Gap Reviewer, grouped) `date` unquoted plain scalar may resolve to YAML's implicit timestamp type under a YAML-1.1 reader, not `String` — added to frontmatter `deferred:` below for Story 2.5's reader to account for.
  - `[defer]` (Intent Alignment Auditor) Missing `auricle/needs-summary` conditional tag (epics.md:1151, AR-DATA-6) — added to frontmatter `deferred:` below; genuinely ambiguous scope, resolved as out of this story's closed test-requirement (epics.md:1173's "every Decision 2.2 variant + combination") rather than an intent gap, since the tag's actual trigger/composition mechanics are specified elsewhere (Epic 9's RunVerb / `published_partial` state), not in Epic 2.

## Design Notes

**`MeetingForFrontmatter` field list** (the renderer's sole input type — all fields pre-resolved by the caller, per the Boundaries rule above):

```swift
public struct MeetingForFrontmatter: Sendable, Equatable {
    public let meetingID: MeetingID
    public let title: String
    public let date: String                    // already "YYYY-MM-DD", caller-resolved
    public let attendees: [String]              // already-wikilinked, e.g. "[[Ben]]" or "[[Speaker_1]]"
    public let schemaVersion: Int               // always 1 for MVP; caller-supplied, not hardcoded here
    public let supersedes: String?              // filename only, re-published variant
    public let needsAttribution: Bool
    public let needsCalendarEnrichment: Bool
    public let summary: String                  // one paragraph, already wikilinked
    public let actionItems: [QuotedItem]
    public let decisions: [QuotedItem]
    public let transcriptSegments: [TranscriptSegment]
    // Carried but intentionally never rendered — see rationale below.
    public let audioPath: String?
    public let calendarEventID: String?
    public let retentionPolicy: String?

    public init(/* memberwise, all fields above */) { /* ... */ }
}

public struct QuotedItem: Sendable, Equatable {
    public let text: String   // e.g. "[[Ben]] will draft the project brief by end of week"
    public let quote: String  // verbatim source quote, rendered as "> <quote>"
}

public struct TranscriptSegment: Sendable, Equatable {
    public let speaker: String  // already-wikilinked, e.g. "[[Ben]]"
    public let text: String
}
```

**Why `audioPath` / `calendarEventID` / `retentionPolicy` exist on `MeetingForFrontmatter` but are never rendered:** epics.md's Story 2.1 AC (line 1145) literally describes the input value as containing "audio path, calendar event ID, ... retention policy" alongside the fields that *do* render. But architecture.md's cross-cutting concern #11 (line 115) and Decision 2.2's `auricle:` block description explicitly name these same three (audio/cache paths, calendar event IDs, retention timer state) as operational data that must live in SQLite and never duplicate into the vault — and the Decision 2.2 schema example itself has no field for any of them. These two documents are in tension on the *input shape*, but not on *output behavior*: nothing in any of the four variant ACs ever asserts these three fields appear in the rendered markdown. This spec resolves the tension by keeping the fields on the struct (satisfying the epic's literal input-shape wording, and leaving room for a future caller need without a breaking signature change) while treating "never rendered" as a first-class, directly tested behavior rather than an implicit omission — see the dedicated I/O-matrix row and acceptance criterion above.

**Golden fixture for the standard variant** (the literal string the standard-variant test should assert against, adapted directly from Decision 2.2's own example so the test doubles as a check that Yams' emitted formatting matches the architecture doc's chosen style — adjust `YAMLEncoder` options, or targeted post-processing of its output, until this matches exactly):

```markdown
---
title: "Tuesday Sync with Ben"
date: 2026-04-28
tags:
  - auricle/meeting
attendees:
  - "[[Ben]]"
auricle:
  meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"
  schema_version: 1
---

Ben and the team reviewed the project timeline and agreed to move up the launch date.

## Action Items

- [[Ben]] will draft the project brief by end of week
  > I'll take a first pass at the brief by Friday

## Decisions

- Move the launch date to May 15
  > Yeah let's push it to the 15th, that gives us another week

## Transcript

**[[Ben]]:** I'll take a first pass at the brief by Friday.
```

(A single-attendee, single-action-item, single-decision, single-transcript-segment fixture keeps the golden string short; the test suite's other variant fixtures only need to vary the fields the I/O matrix calls out, not re-derive a new golden shape from scratch.)

**Re-published variant's `auricle:` block** (illustrating where `supersedes` lands relative to `schema_version` — comes after, per the Boundaries key-order rule):

```yaml
auricle:
  meeting_id: "01HJK3PQXY7N8M3FT4QHNWVZRP"
  schema_version: 1
  supersedes: "2026-04-28-tuesday-sync-with-ben.md"
```

## Verification

**Commands:**
- `swift test --filter PersistTests` -- expected: all `FrontmatterRendererTests` pass, including the 8 scenario tests and the markdown-discipline test.
- `swift build` -- expected: clean build with the new Yams dependency resolved.

## Auto Run Result

**Summary:** Implemented `Persist/FrontmatterRenderer.swift` and its input type `Persist/MeetingForFrontmatter.swift`, rendering all 4 Decision 2.2 variants (standard, publish-anyway, calendar-enrichment-failed, re-published) plus their combination into Decision 2.2-shaped YAML frontmatter + fixed-order body markdown, using a hand-built Yams `Node` tree (rather than a `Codable`-driven `YAMLEncoder`, because libyaml's default block-sequence indentation didn't match Decision 2.2's literal example — see Design Notes). One review pass found and fixed a real Unicode-escaping defect and a real line-wrapping defect in the Yams serialization call.

**Files changed:**
- `Package.swift` -- added the Yams package dependency and wired it into the `Persist` target.
- `Package.resolved` -- pinned Yams 5.4.0.
- `Sources/Persist/MeetingForFrontmatter.swift` -- new. The renderer's sole input type (`MeetingForFrontmatter`, `QuotedItem`, `TranscriptSegment`).
- `Sources/Persist/FrontmatterRenderer.swift` -- new. `FrontmatterRenderer.render(meeting:) -> String`, the pure rendering function.
- `Sources/Persist/ManifestPlaceholder.swift` -- deleted (target no longer empty).
- `Tests/PersistTests/FrontmatterRendererTests.swift` -- new, 12 `@Test`s covering every I/O-matrix row, the markdown-discipline contract, and the 3 patch-round regression tests (non-ASCII text, long-title no-wrap, empty-summary blank-line count).

**Review findings breakdown** (22 raw findings across 4 review layers; full detail in `## Review Triage Log` above):
- **Patched (6 entries, all fixed and re-verified):** (1) `[high]` non-ASCII characters (accented text, CJK, em-dash) were rendered as `\uXXXX` escape sequences instead of literal UTF-8 -- fixed by passing `allowUnicode: true`. (2) `[medium]` long titles got line-wrapped mid-scalar by libyaml's default width -- fixed by passing `width: -1`. (3) `[low]` a do/catch comment referenced "this story's contract" instead of stating the constraint directly -- reworded. (4) `[low]` an empty `summary` produced an extra blank line before `## Action Items` -- fixed by filtering empty components before joining in `renderBody`. (5) `[low]` `MeetingForFrontmatter`'s doc comment misattributed title/wikilink derivation to `FilenameResolver`/Story 2.2, which doesn't touch those fields -- reworded. (6) `[low]` a test fixture (`standardGolden`) had inconsistent string-literal indentation vs. the rest of the file -- moved inline to match.
- **Deferred (2 entries, added to frontmatter `deferred:`):** the `date` field's unquoted-plain-scalar shape (mandated by Decision 2.2 itself) may resolve to a YAML timestamp type under a YAML-1.1 reader, relevant to Story 2.5's reader; and the `auricle/needs-summary` tag named in epics.md's own AC text but excluded by Decision 2.2's variant table and this story's own literal test-requirement sentence -- its actual trigger/composition lives in Epic 9's RunVerb story, not Epic 2.
- **Rejected, with reason (14 findings):** 10 verified `false` (refuted with cited evidence -- see triage log for each: the `fatalError` catch branch is unreachable given the fixed-shape all-scalar input; `sortKeys`'s default is exactly what's needed and the mapping's order is fixed by construction anyway; the sequence-reindent helper's single-sequence assumption is already documented in its own doc comment, contrary to the finding's claim; no behavior differs for a non-`1` `schemaVersion`; malformed/YAML-unsafe `date` and embedded-heading-syntax findings both require caller input this story's boundaries explicitly declare out of trust scope, with the `date` sub-claim's crash-path portion independently refuted; and 3 process-level findings about `sprint-status.yaml`, an unrecorded "blocked" gate check, and unevidenced verification are each addressed by this workflow's own conventions, not by this diff). 1 `low` finding rejected as out of proportion to fix (the spec asked for a `Codable`-struct approach; the code instead hand-builds a `Node` tree, a reasonable and already-anticipated adaptation given the indentation constraint, with no behavioral gap).

**Follow-up review recommendation: `true`.** This pass patched one `high`-severity entry. The specific unverified residual risk: while patching the Unicode-escaping defect, the implementer discovered libyaml cannot emit any UTF-8 sequence encoding a code point above U+FFFF (its `IS_PRINTABLE` check is 3-byte-max) regardless of `allowUnicode` -- meaning emoji and other supplementary-plane characters in a calendar title will *still* render as escape sequences, unlike the BMP characters (accented letters, CJK, em-dash) the new test now covers. This is a real, currently-untested gap in the same code path the high-severity patch touched, and is worth a follow-up pass's judgment on whether it needs an explicit accepted-limitation note/test or is acceptable as-is.

**Verification performed:** `swift build` (clean, both before and after patching); `swift test --filter PersistTests` (9/9 before patching, 12/12 after); full `swift test` (130/130 before, 133/133 after -- no regressions elsewhere); `swiftlint lint --strict` and `swiftformat --lint` against every new/changed file (0 violations, both before and after patching). All commands run directly by the orchestrating agent, not only reported by the implementation subagent.

**Residual risks:** the two deferred items above (date-as-plain-scalar type ambiguity for Story 2.5's reader; the out-of-scope `needs-summary` tag for a later story), plus the named follow-up risk (supplementary-plane Unicode/emoji in titles still escapes, a libyaml hard limit with no known workaround short of a custom post-processing pass this story chose not to add speculatively).

## Finalization

Commit initially blocked, then completed with explicit user authorization to bypass the hook. `git commit` could not complete normally because this repository's `.githooks/pre-commit` hook crashes every time it is invoked as a direct child of `git commit` in this environment. The user was asked and explicitly authorized `git commit --no-verify` for this specific commit, and separately asked for the hook crash itself to be spun out as a follow-up debugging task (done — see the spawned task). No further hook bypass is authorized beyond this one commit.

**Diagnosis (root cause investigation, not a code defect in this story's diff):**
- The hook runs `mise exec -- swiftformat --lint .` (passes) then `mise exec -- swiftlint lint --strict .`, which crashes with `Illegal instruction: 4` — every single time, with no variation across 4+ attempts.
- The crash is **not caused by this story's changes**: it reproduces identically on `git commit --allow-empty` (zero content changes) in this same working tree.
- The crash is **not reproducible** when the exact same command (`mise exec -- swiftlint lint --strict .`, with `MISE_PYTHON_GITHUB_ATTESTATIONS=false` to work around an unrelated global `~/.tool-versions` python-attestation failure) is run directly, via a nested `sh -c`, or via `.githooks/pre-commit` invoked directly as a script (all outside `git commit`) — every one of those succeeds cleanly with "0 violations" across all 96 Swift files, repeated 5+ times.
- Ruled out: stdin source, `GIT_DIR`/`GIT_INDEX_FILE`/`GIT_EDITOR` env vars, an extra shell-nesting layer, and Bash-tool sandboxing (`dangerouslyDisableSandbox: true` made no difference).
- Not ruled out / not investigated further (would require instrumenting git's own hook-invocation internals, out of this story's scope): whatever git's internal hook-runner does differently from a shell `exec` when spawning `.githooks/pre-commit` as its own child (fd/pipe setup, process group, or similar) is the remaining candidate.

**What was deliberately NOT done:** `git commit --no-verify` was not used. Per this agent's operating rules, hooks are never skipped without explicit user authorization, regardless of how confidently a hook failure has been diagnosed as environment-related rather than code-related.

**Current repository state (safe, no data loss):** all Story 2.1 files exist on disk and are `git add`-staged, exactly as verified above (`Package.swift`, `Package.resolved`, `Sources/Persist/FrontmatterRenderer.swift`, `Sources/Persist/MeetingForFrontmatter.swift`, deletion of `Sources/Persist/ManifestPlaceholder.swift`, `Tests/PersistTests/FrontmatterRendererTests.swift`, this spec file, and `epic-2-context.md`). Nothing has been committed. `swift build`, `swift test` (133/133), `swiftlint --strict`, and `swiftformat --lint` all pass cleanly when run directly.

**Recommended next step for a human:** investigate why `.githooks/pre-commit`'s `mise exec -- swiftlint lint --strict .` line crashes with SIGILL specifically when spawned as `git commit`'s own hook child process, but not under any other invocation method tried above. Once resolved (or if the hook is intentionally adjusted), the staged changes in this worktree are ready to commit as-is with no further code changes needed.
