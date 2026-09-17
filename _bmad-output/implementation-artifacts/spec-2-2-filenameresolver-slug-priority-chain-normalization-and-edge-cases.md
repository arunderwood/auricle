---
title: 'FilenameResolver — Slug Priority Chain, Normalization, and Edge Cases'
type: 'feature'
created: '2026-09-16'
status: 'done'
baseline_revision: '1224f80f44752d6c556df0c43edf8813ecfae8d7'
review_loop_iteration: 3
followup_review_recommended: false
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      Characters with no NFKD compatibility decomposition to ASCII (German ß, ligatures
      like æ/œ) silently vanish during slug normalization the same way CJK and emoji do,
      rather than transliterating to an ASCII equivalent (e.g. ß -> ss).
    evidence: |-
      Not caused by this diff: Decision 2.4 (architecture.md:919-985) explicitly mandates
      NFKD compatibility decomposition as the normalization algorithm, and this story
      correctly implements exactly that. NFKD's decomposition table has no mapping for ß/æ/œ
      to ASCII (unlike accented Latin letters, which decompose into base + combining mark).
      This is an inherent consequence of the architecturally-chosen algorithm, not a defect
      introduced here. What would settle it: whether a future revision of Decision 2.4 wants
      a supplementary transliteration table for these specific characters, weighed against
      the added complexity for a narrow set of European-language titles.
    location: >-
      Sources/Persist/FilenameResolver.swift (normalize function)
    severity: low (unverified) -- narrow character set, graceful fallthrough to the next slug source rather than a crash or corrupted output
  - summary: >-
      Non-ASCII punctuation with no NFKD decomposition to ASCII -- en dashes, em dashes, and
      similar -- is deleted rather than treated as a word separator, silently merging the words
      on either side (e.g. "Q3-Q4 Planning" with an en dash normalizes to "q3q4-planning", not
      "q3-q4-planning").
    evidence: |-
      Not caused by this diff, for the same reason as the ß/æ/œ item above: Decision 2.4
      mandates "strip all non-ASCII characters" as a fixed pipeline step, with no
      separator-aware exception for punctuation. Verified directly: an en dash and an em dash
      both have no NFKD compatibility decomposition (they aren't accented-letter-shaped), so
      they fall to the strip step exactly like CJK or emoji, but unlike those, the ASCII text
      on both sides survives and now runs together. This is plausibly a more common real-world
      trigger than ß/æ/œ, since dashes are routine in calendar-app-generated titles. What would
      settle it: whether a future revision of Decision 2.4 wants the strip step to special-case
      dash-family punctuation (treat as a separator, like whitespace) ahead of the general
      non-ASCII strip.
    location: >-
      Sources/Persist/FilenameResolver.swift (normalize function)
    severity: low (unverified) -- degrades slug readability for affected titles, never crashes or produces an invalid filename
---

<intent-contract>

## Intent

**Problem:** `Persist/FilenameResolver.swift` doesn't exist yet. Nothing in the codebase can turn meeting metadata into the deterministic `<YYYY-MM-DD>-<slug>.md` filename Decision 2.4 specifies, so `VaultWriter` (Story 2.3) and `PersistStage` (Story 2.4) have no way to name a vault note.

**Approach:** Add a `MeetingForFilename` input type and a pure `FilenameResolver.resolve(meeting:ordinal:) -> String` function in the existing `Persist` target, implementing Decision 2.4's 4-source slug priority chain (calendar title → named attendees → time-of-day → id-prefix), its 8-step normalization pipeline, and the same-Mac ordinal-collision suffix.

## Boundaries & Constraints

**Always:**
- `FilenameResolver.resolve(meeting:ordinal:)` is a pure, non-throwing, synchronous function: `(MeetingForFilename, Int?) -> String`. No file I/O, no logging, no `Date`/`Calendar`/`TimeZone` reads — collision *detection* (checking whether a filename already exists) is `VaultWriter`'s job (Story 2.3); this function only *formats* whichever `ordinal` it's given.
- `meeting.captureDate` ("YYYY-MM-DD") and `meeting.captureTime24h` ("HHMM", 24-hour) arrive **pre-resolved by the caller** in the user's local timezone at capture time — this function never derives local time from a `Date`/UTC timestamp itself. (Same "pre-resolved by caller" boundary Story 2.1's `FrontmatterRenderer` uses for `date`, for the same reason: keeps this function a deterministic string transform, testable without mocking system timezone/locale.)
- Slug priority chain, tried in order, falling through whenever a source produces an empty normalized string:
  1. `meeting.calendarEventTitle`, normalized.
  2. `with-<other-1>[-and-<other-2>]`, built from `meeting.attendees` with `meeting.selfWikilink` filtered out and normalized — see Design Notes for the exact per-name-normalization algorithm (corrected across review iterations 1 and 2; the ready-for-development bar is a source that never produces a glue-word-only slug, never joins more than 2 named others regardless of whether self was identifiable, and never exceeds the 60-character cap even when individually-short names combine past it).
  3. `meeting-at-<captureTime24h>` (always non-empty by construction — 4-digit 24h local time).
  4. `meeting-<first-8-chars-of-meetingID.rawValue>`, lowercased — a defensive terminal fallback; per Decision 2.4 this is expected unreachable in practice since source 3 always yields a valid slug, and is implemented for completeness rather than covered by a forced test.
- Normalization pipeline (applied to whichever candidate string is being tried, source 1 and the assembled source-2 string alike): (1) Unicode NFKD-compatibility decomposition (`decomposedStringWithCompatibilityMapping`); (2) strip every non-ASCII scalar; (3) lowercase; (4) replace every run of one-or-more non-`[a-z0-9]` characters with a single hyphen; (5) strip leading/trailing hyphens; (6) collapse any remaining consecutive hyphens; (7) if longer than 60 characters, truncate at the last hyphen at-or-before the 60th character (drop the hyphen itself), or hard-cut at 60 if no hyphen is found in that range; (8) if the result is empty, the source produced nothing usable — fall through to the next source.
- `resolve(meeting:ordinal:)`'s `ordinal` parameter: `nil` or `1` → filename has no ordinal suffix (`<date>-<slug>.md`); `2` or greater → `<date>-<slug>-<ordinal>.md`. Callers (`VaultWriter`, Story 2.3) are responsible for checking the filesystem and incrementing `ordinal` until an unused name is found — this function only formats a given ordinal, it never discovers or picks one.
- Output is always `<date>-<slug>.md` or `<date>-<slug>-<ordinal>.md` — the full filename including the `.md` extension.

**Never:**
- Never touch the filesystem, `AtomicWriter`, or `StateStore` from this story.
- Never construct the re-publish `--rerun-<date>` suffix (Decision 2.3) — that's `PersistStage`'s concern (Story 2.4), a different suffix axis (double-hyphen + date) from this story's same-day-collision suffix (single-hyphen + ordinal), deliberately kept visually and mechanically distinct per Decision 2.4.
- Never introduce a snapshot-testing library — hand-written expected-string literals via Swift Testing (`import Testing`, `@Test`, `#expect`), matching this repo's house style (see Story 2.1's `FrontmatterRendererTests.swift`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Calendar title, plain ASCII | `calendarEventTitle: "Tuesday Sync"`, `captureDate: "2026-04-28"` | `"2026-04-28-tuesday-sync.md"` | No error expected |
| Accented calendar title (NFKD) | `calendarEventTitle: "Café résumé"` | slug source 1 succeeds: `"cafe-resume"` | No error expected |
| CJK calendar title | `calendarEventTitle: "北京会议"`, no attendees, `captureTime24h: "1423"` | NFKD + ASCII-strip yields empty; falls through to source 3: `"meeting-at-1423"` | No error expected |
| All-emoji calendar title | `calendarEventTitle: "🎉🎉🎉"`, no attendees, `captureTime24h: "0930"` | Falls through to source 3: `"meeting-at-0930"` | No error expected |
| Mixed emoji + ASCII calendar title | `calendarEventTitle: "🎉 Launch!"` | Slug source 1 succeeds: `"launch"` | No error expected |
| No calendar title; 1:1 with a named attendee | `calendarEventTitle: nil`, `attendees: ["[[Ben]]", "[[Jordan]]"]`, `selfWikilink: "[[Jordan]]"` | Source 2: self (`Jordan`) filtered out, `"with-ben"` | No error expected |
| No calendar title; self + 2 named others (3 total) | `attendees: ["[[Jordan]]", "[[Ben]]", "[[Jordan Whitfield]]"]`, `selfWikilink: "[[Jordan]]"` | Source 2: `"with-ben-and-jordan-whitfield"` | No error expected |
| No calendar title; self + 3 named others (4 total, exceeds cap) | 4 total attendees including self, all named | Source 2 doesn't apply (3 non-self names remain, exceeds the 2-name cap); falls through to source 3 | No error expected |
| No calendar title; 3 attendees, none matches `selfWikilink` (self not identified) | `attendees: ["[[Ben]]", "[[Chris]]", "[[Dana]]"]`, `selfWikilink: nil` | Source 2 doesn't apply (3 non-self names remain after filtering, exceeds the 2-name cap); falls through to source 3 — never joins all 3 | No error expected |
| No calendar title; every attendee equals `selfWikilink` (self-only meeting) | `attendees: ["[[Jordan]]"]`, `selfWikilink: "[[Jordan]]"` | Source 2 doesn't apply (0 names remain after filtering); falls through to source 3 | No error expected |
| No calendar title; named attendees whose normalized form is entirely empty | `attendees: ["[[北京]]", "[[东京]]"]`, `selfWikilink: nil` | Source 2 doesn't apply (0 non-empty normalized names remain — never produces a glue-word-only slug like `"with-and"`); falls through to source 3 | No error expected |
| No calendar, no named attribution | `calendarEventTitle: nil`, `attendees: []`, `captureTime24h: "1423"` | Source 3: `"meeting-at-1423"` | No error expected |
| Extremely long calendar title | `calendarEventTitle: "This is an extremely long meeting title that exceeds the slug length cap"` | Truncated at the last hyphen ≤60 chars: `"this-is-an-extremely-long-meeting-title-that-exceeds-the"` (56 chars) | No error expected |
| Calendar title whose normalized slug is exactly 60 characters | a normalized candidate of exactly 60 chars | Passed through unmodified — the 60-char cap triggers only when the length exceeds 60, not when it equals 60 | No error expected |
| Calendar title that normalizes to one long hyphen-free run over 60 characters | e.g. 70 consecutive letters, no separators | Hard-cut to exactly 60 characters (no hyphen in range to cut at instead) | No error expected |
| Explicit empty-string calendar title, distinct from `nil` | `calendarEventTitle: ""`, `attendees: ["[[Ben]]"]`, `captureTime24h: "1000"` | Normalizes to empty, same as `nil` would; falls through past source 1 (to source 2, `"with-ben"`, in this example) | No error expected |
| Two attendee names each individually under 60 characters, but combining past it | e.g. two ~50-character real names as the only 2 attendees (self identified separately) | Each name is capped at 25 characters (at a hyphen boundary within that shorter window, or hard-cut if none) *before* joining, so the assembled `with-<name>-and-<name>` slug never exceeds 60 characters by construction | No error expected |
| A single surviving attendee name longer than 25 characters with no internal hyphen at all (a one-word identifier) | e.g. attendees: one 40-character unbroken name, self identified separately | Hard-cut to exactly 25 characters (no hyphen within that window to cut at instead) — never collapses to the bare word `"with"` | No error expected |
| Exactly one of two candidate attendee names normalizes to empty, the other doesn't | `attendees: ["[[Ben]]", "[[北京]]"]`, `selfWikilink: nil` | The empty-normalizing name is discarded; the surviving single name is used alone: `"with-ben"` | No error expected |
| Same-Mac collision, no ordinal yet | `resolve(meeting:, ordinal: nil)` | `"<date>-<slug>.md"`, no numeric suffix | No error expected |
| Same-Mac collision, ordinal 2 | `resolve(meeting:, ordinal: 2)` | `"<date>-<slug>-2.md"` | No error expected |

</intent-contract>

## Code Map

- `Sources/Persist/MeetingForFilename.swift` -- new. The resolver's sole input type.
- `Sources/Persist/FilenameResolver.swift` -- new. `public enum FilenameResolver { public static func resolve(meeting: MeetingForFilename, ordinal: Int? = nil) -> String }`.
- `Sources/Persist/MeetingForFrontmatter.swift` -- existing (Story 2.1). Same "pre-resolved by caller, pure formatting function" pattern to follow for `MeetingForFilename`; not a dependency, just the sibling convention.
- `Sources/Core/MeetingID.swift` -- existing; `meetingID.rawValue` is the 26-char uppercase ULID string `resolve`'s source-4 fallback takes `.prefix(8)` of (then lowercases, matching every other slug source's lowercase output).
- `_bmad-output/planning-artifacts/architecture.md:919-985` -- Decision 2.4 (filename convention, slug priority chain, normalization steps, edge-case table, collision handling) — the normative source for this story.
- `_bmad-output/planning-artifacts/architecture.md:899-917` -- Decision 2.3 (re-publish `--rerun-<date>` suffix) — read only to confirm it's *not* this story's concern (Story 2.4's, per Boundaries above).
- `_bmad-output/planning-artifacts/epics.md:1178-1218` -- Story 2.2's full acceptance criteria (already distilled into this spec's intent-contract).
- `_bmad-output/implementation-artifacts/epic-2-context.md` -- Epic 2 context (goal, cross-story dependencies); confirms Stories 2.1-2.3 are independent leaf components with no inter-story code dependency.
- `Package.swift` -- `PersistTests` target already depends on `["Persist", "TestSupport"]` (find the `.testTarget(name: "PersistTests", ...)` entry directly rather than trusting a specific line number here, since Story 2.1 already shifted this once by adding the Yams dependency above it); no target wiring needed.
- Foundation's `String.decomposedStringWithCompatibilityMapping` is NFKD (verified: Han ideographs and emoji have no compatibility decomposition to ASCII, so they correctly strip to empty in step 2 of the normalization pipeline; accented Latin letters decompose to base + combining mark, and the combining mark is what step 2 strips) — no third-party Unicode library needed.

## Tasks & Acceptance

**Execution:**
- `Sources/Persist/MeetingForFilename.swift` -- define `MeetingForFilename` (`meetingID`, `captureDate`, `captureTime24h`, `calendarEventTitle`, `attendees`, `selfWikilink`) -- the resolver's sole input surface.
- `Sources/Persist/FilenameResolver.swift` -- implement `resolve(meeting:ordinal:)`, the 4-source priority chain, and the shared normalization pipeline (NFKD → strip-non-ASCII → lowercase → kebab → trim/collapse hyphens → 60-char cap at hyphen boundary) -- the actual behavior under test.
- `Tests/PersistTests/FilenameResolverTests.swift` -- new. One `@Test` per I/O-matrix row above — count them directly from the matrix rather than trusting a number restated here, since this exact count has drifted twice already across review iterations as rows were added. Covers every edge case named in Story 2.2's own AC test-coverage list (accented, CJK, all-emoji, mixed-emoji, no-calendar+attendees, no-calendar+no-attribution, length-cap, ordinal counter) plus the 3-total/4-total attendee boundary, the self-not-identified boundary, the self-only and empty-normalized-names fallthroughs, the partial-empty-normalize case, the 60/61-character truncation edges on a calendar title, the per-name 25-character truncation edge within source 2, the explicit-empty-string calendar title, the plain-ASCII happy path, and the ordinal suffix rule.

**Acceptance Criteria:**
- Given a `MeetingForFilename` with a calendar title, when `FilenameResolver.resolve(meeting:)` is called, then the normalized title becomes the slug and the output is `<captureDate>-<slug>.md`.
- Given a calendar title whose normalization yields an empty string (CJK, all-emoji), when resolved, then the resolver falls through to the next priority source in order, never producing an empty or malformed slug.
- Given 1 or 2 non-self attendees remain after filtering `selfWikilink` and normalizing each name individually (discarding any that normalize to empty), when resolved (and no usable calendar title), then the slug is `with-<other>[-and-<other>]`, self omitted, and never exceeds 60 characters even when the surviving name(s) are individually long.
- Given 0, or more than 2, non-self non-empty-normalized attendee names remain, when resolved (and no usable calendar title), then source 2 is skipped and the resolver falls through to `meeting-at-<captureTime24h>` — regardless of the raw (pre-filter, pre-normalize) `attendees.count`.
- Given a slug candidate longer than 60 characters, when resolved, then the output slug is truncated at the last hyphen at-or-before character 60, never cutting mid-word, and never exceeding 60 characters.
- Given `ordinal: 2` (or any value `>= 2`), when resolved, then the output filename has `-<ordinal>` inserted immediately before `.md`; given `ordinal: nil` (or `1`), the filename has no ordinal suffix.

## Spec Change Log

### 2026-09-16 — Review pass 1 (bad_spec)

**Triggering findings:** Blind Hunter and Edge Case Hunter both independently found, and this agent independently verified by direct execution, that the originally-specified source-2 algorithm ("filter self, then normalize the assembled `with-...` string as one whole blob, gated on `meeting.attendees.count <= 3`") produces two classes of wrong output: (1) when `selfWikilink` doesn't match any entry in `attendees` (nil, or self simply not present) and up to 3 named attendees remain, it joins all 3 with `-and-` instead of falling through — exceeding the documented 2-name template; (2) when every remaining attendee name normalizes to an empty string (e.g. names given only in a script with no ASCII form, like CJK), the literal glue words `with`/`and` survive the whole-blob normalization pass and the function returns a meaningless `"with-and"` slug instead of falling through to source 3. Verified directly: `resolve()` with `attendees: ["[[北京]]", "[[东京]]"]` returned `"...-with-and.md"`.

**What was amended:** Boundaries item 2 (source-2 algorithm) simplified to a high-level statement deferring the algorithm to Design Notes, where it's corrected to normalize each attendee name individually (discarding names that normalize to empty) before joining, and to gate on the post-filter, post-normalize count of surviving names rather than on `meeting.attendees.count` before filtering. The I/O & Edge-Case Matrix gained 5 rows covering the two newly-discovered failure classes plus the 60/61-character truncation-boundary gaps a Verification Gap finding separately surfaced. Frontmatter `deferred` gained one item (NFKD's inherent inability to transliterate ß/æ/œ — a pre-existing consequence of Decision 2.4's mandated algorithm, not something this amendment changes).

**Known-bad state avoided:** a same-Mac collision with >2 identifiable attendees, or with any attendee named in a non-Latin script, would have shipped either an over-long `with-a-and-b-and-c` filename or a semantically empty `with-and` filename — both violate Decision 2.4's documented shape and the "never produces an empty or malformed slug" acceptance criterion.

**KEEP instructions (must survive re-derivation):** everything else about the original implementation was correct and independently verified — the overall function signature and purity (`resolve(meeting:ordinal:) -> String`, no I/O), the `MeetingForFilename` field list exactly as drafted, the calendar-title-first / attendees-second / time-of-day-third / id-prefix-fourth priority order, the NFKD → strip-non-ASCII → lowercase → kebab-case → trim pipeline (steps 1-6) exactly as specified, the last-hyphen-boundary truncation algorithm (including its documented hard-cut fallback when no hyphen exists in range — confirmed correct as specified, not a defect), the ordinal-suffix formatting rule, and the file layout (`Sources/Persist/MeetingForFilename.swift`, `Sources/Persist/FilenameResolver.swift`, `Tests/PersistTests/FilenameResolverTests.swift`). Re-derive by keeping all of this and replacing only the source-2 (`attendeeSlug`) construction per the corrected Design Notes algorithm.

### 2026-09-16 — Review pass 2 (bad_spec)

**Triggering findings:** Blind Hunter, Edge Case Hunter (as a high-confidence claim), and the Verification Gap Reviewer all independently found — and this agent independently confirmed by direct execution against a standalone copy of the algorithm — that iteration 1's fix for source 2 introduced a regression: normalizing each attendee name individually (each capped at 60 characters on its own) and joining with `with-`/`-and-` glue, with no further truncation, means the *assembled* slug can exceed 60 characters even though no single piece does. Two realistic long names produced a 95-107 character slug in the reviewers' reproductions. This directly violates this story's own Boundaries text, which already said normalization "appl[ies]... to the assembled source-2 string alike" — iteration 1's Design Notes contradicted that by explicitly saying "no second normalization pass over the joined string," incorrectly conflating "don't re-run NFKD/ASCII/lowercase/kebab" (correct, those are already done per-piece) with "don't re-truncate" (wrong, length is a property of the whole assembled string). Blind Hunter separately found the iteration-1 amendment left the *original*, now-superseded rationale paragraph in Design Notes standing alongside the new one, directly contradicting it. Blind Hunter also found a stale `Package.swift:141` line reference in the Code Map (Story 2.1 shifted it to 146 by adding the Yams dependency) and a vacuous `if !timeOfDaySlug.isEmpty` conditional in `slug(for:)` that can never be false.

**What was amended:** Design Notes' source-2 algorithm rewritten as a single authoritative numbered sequence (removing the now-superseded "normalized as a whole" paragraph entirely rather than leaving it to contradict the corrected one), adding the missing step: re-run `truncate()` alone (not the full normalize pipeline) over the final assembled `with-...` string. Design Notes also now documents the vacuous-conditional cleanup. Code Map's `Package.swift` reference dropped its specific line number in favor of a description that doesn't drift. I/O matrix gained 2 rows: an explicit empty-string calendar title, and the assembled-slug-exceeds-60-characters case.

**Known-bad state avoided:** a same-Mac collision or ordinary publish for a meeting with 2 named attendees whose combined normalized names exceed 60 characters (plausible for real full names, e.g. hyphenated surnames) would have shipped a filename well past Decision 2.4's documented cap, with no test catching it — the exact same class of "ships broken, nothing red" failure the iteration-1 fix was meant to close for a different input shape.

**KEEP instructions (must survive re-derivation):** everything kept from iteration 1 remains correct: overall signature/purity, `MeetingForFilename` field list, priority-chain order, the per-name normalization within source 2 (NFKD → ASCII → lowercase → kebab → trim → per-name truncate, then discard-empties, then gate on ≤2 survivors), the calendar-title and time-of-day sources, the ordinal-suffix rule, and the file layout. Re-derive by keeping all of that and adding exactly one step to `attendeeSlug`: after joining survivors with `with-`/`-and-`, pass the assembled string through the truncation logic (not the full normalize pipeline) before returning it. Also apply the two small, unrelated cleanups found in the same pass: drop the vacuous `if` around the time-of-day return, and add the two new I/O-matrix test rows (empty-string calendar title, assembled-slug-over-60).

### 2026-09-16 — Review pass 3 (bad_spec)

**Triggering findings:** Blind Hunter and Edge Case Hunter (as a high-confidence claim) both independently found, and this agent independently verified by direct execution, that iteration 2's fix (join per-name-normalized attendee names, then re-run `truncate()` over the assembled `with-...` string) has a sharper failure mode than the bug it fixed: `truncate()`'s hyphen-boundary rule cuts at the *last* hyphen at-or-before character 60, and for a single long hyphen-free attendee name, the only hyphen within that window can be the one right after `with-` itself. Verified directly: a single 58-character hyphen-free attendee name produced the slug `"with"` — strictly worse than iteration 1's `"with-and"` bug, since not even a placeholder connector word's worth of attendee identity survives. Blind Hunter also found: (a) an untested branch where exactly one of two candidate attendee names normalizes to empty (the code already handles it correctly — `with-ben` — but nothing exercised it); (b) this spec's own Tasks & Acceptance "Acceptance Criteria" bullets (this section, outside intent-contract) still described the pre-iteration-1 gating rule (`meeting.attendees.count <= 3` / `> 3`) rather than the corrected post-filter-count rule, left un-updated across two prior amendments; (c) the Tasks section's stated test count ("20 tests") had drifted from the actual row count more than once as rows were added; (d) real, non-ASCII dash characters (en dash, em dash) get deleted rather than treated as word separators during normalization, merging adjacent words (e.g. an en-dash "Q3-Q4 Planning" → `q3q4-planning`) — architecturally inherited from Decision 2.4's own "strip all non-ASCII" rule, the same category as the already-deferred ß/æ/œ item, not a defect this diff introduces.

**What was amended:** Design Notes' source-2 algorithm restructured a third time: instead of joining full-length per-name-normalized names and truncating the *assembled* result afterward (iteration 2's approach, which has the hyphen-collapse failure mode above), each surviving name is now normalized with a **25-character** cap (not 60) *before* joining — a budget derived from the fixed glue-text lengths (`with-` = 5, `-and-` = 5, worst case 2 names: `(60-5-5)/2 = 25`), which guarantees the assembled slug can never exceed 60 characters by construction, with no second truncation pass needed at all. The stale Tasks & Acceptance AC bullets were rewritten to match the actual (post-filter-count) gating rule. The stale, drift-prone "N tests" count was replaced with an instruction to count matrix rows directly rather than trust a restated number. Three new I/O-matrix rows were added (per-name 25-char truncation edge, partial-empty-normalize, and the existing "two long names" row's expected behavior was corrected to describe per-name capping rather than assembled-string truncation). Frontmatter `deferred` gained a second item (non-ASCII dash punctuation), alongside the existing ß/æ/œ entry. The Verification section gained `swiftformat --lint` / `swiftlint --strict`, matching what this agent has actually been running as its own verification all along, with an explicit note that the repo's full `scripts/check.sh` (release build + Xcode project builds) is a broader pre-push gate out of scope for a single story.

**Known-bad state avoided:** a meeting whose only identifiable attendee has a single-token name (a handle, or any name without an internal space or hyphen) longer than roughly 55 characters would have published a vault note named literally `with.md` — a same-day collision with every *other* such meeting and zero identifying information recoverable from the filename, categorically worse than any prior iteration's bug.

**KEEP instructions (must survive re-derivation):** everything kept from iterations 1 and 2 remains correct except the exact truncation mechanics within `attendeeSlug`: overall signature/purity, `MeetingForFilename` field list, priority-chain order, the discard-empties-then-gate-on-≤2-survivors logic, the calendar-title source's own 60-char normalize (unchanged — this bug and fix are specific to source 2 only), the time-of-day source, the ordinal-suffix rule, the vacuous-conditional cleanup from iteration 2, and the file layout. Re-derive `attendeeSlug` specifically to normalize each surviving name with a 25-character cap *before* joining (rather than joining at full length and truncating after), and add the three new I/O-matrix rows as tests.

## Review Triage Log

### 2026-09-16 — Review pass
- verdicts: 20 findings — high 0, medium 0, low 0, false 17, maybe-false 0 (2 findings route to `bad_spec`, 1 to `defer` — not counted in the false/verified tally above since those routes aren't a severity verdict)
- findings:
  - `[bad_spec]` (Blind Hunter) `attendeeSlug` joins all 3 names when `selfWikilink` is nil or doesn't match any attendee and ≤3 total attendees remain, exceeding the documented 2-name `with-...` template — verified by direct execution (`attendees: ["[[Ben]]","[[Chris]]","[[Dana]]"], selfWikilink: nil` → `"...-with-ben-and-chris-and-dana.md"`). Root cause: Boundaries item 2 gated on `meeting.attendees.count <= 3` before filtering, which doesn't bound the post-filter "others" count when self isn't found. Amended (see Spec Change Log).
  - `[bad_spec]` (Edge Case Hunter, same underlying algorithm) title/attendee names that normalize entirely empty produce a bare `with-and` slug — verified by direct execution (`attendees: ["[[北京]]","[[东京]]"]` → `"...-with-and.md"`). Root cause: whole-blob normalization let literal glue words survive. Amended (see Spec Change Log) alongside the finding above, in the same algorithm correction.
  - `[false]` `[reject]` (Blind Hunter) The id-prefix fallback's unreachability comment states an imprecise reason (attributes unreachability to `captureTime24h`'s content rather than the `"meeting-at-"` literal prefix alone) — real wording imprecision, but purely a would-be code-comment nit inside code that no longer exists after the revert; the corrected Design Notes now states the precise reason for the re-derivation to pick up.
  - `[false]` `[reject]` (Blind Hunter) No test for the "solo self-only meeting" fallthrough (via the `!others.isEmpty`-equivalent branch specifically, as opposed to the count-exceeds-cap branch) — verified the existing (pre-revert) code already handled this correctly (`attendees: ["[[Jordan]]"], selfWikilink: "[[Jordan]]"` → correctly fell through to `"meeting-at-1000.md"`); a real test-coverage gap, not a live bug — folded into the amended I/O matrix's new "self-only" row rather than triaged as a standalone patch, since the same re-derivation pass will produce a fresh test suite from the corrected matrix.
  - `[false]` `[reject]` (Blind Hunter) No de-duplication of repeated attendee entries (e.g. two `"[[Ben]]"`) — no demonstrated realistic path produces duplicate entries in an attendee list from a legitimate calendar/attribution source; even if it occurred, `with-ben-and-ben` is not incorrect or crashing, just aesthetically redundant. Matches this epic's established "trust the caller's pre-resolved input" boundary (Story 2.1 applies the same standard).
  - `[false]` `[reject]` (Blind Hunter) Slug source 4 (id-prefix fallback) has zero test coverage, risking an undetected mistake (e.g. wrong case or wrong end of the ULID) — accepted precedent: the function proves this branch unreachable via the public API (source 3 can never be empty), matching how Story 2.1's own unreachable `fatalError` branch was accepted without a forced test.
  - `[false]` `[reject]` (Blind Hunter) `truncated` has no minimum-length safeguard — a short first word before one long unbroken word could truncate to just 1-2 characters — this is the explicitly documented trade-off of "never cut mid-word" (Decision 2.4's own stated rule), not a deviation from it; no minimum length was ever specified, and inventing one would be scope creep.
  - `[false]` `[reject]` (Blind Hunter) The spec's Design Notes duplicates `MeetingForFilename.swift`'s source verbatim, risking drift — the fix is to edit this build's spec, which this workflow's own triage rules exclude from patch/bad_spec handling; noted but not actioned as a code or behavior finding.
  - `[defer]` (Blind Hunter) Characters with no NFKD compatibility decomposition to ASCII (ß, æ, œ) silently vanish rather than transliterating — not caused by this diff (Decision 2.4 itself mandates NFKD, and this is implemented exactly as specified); added to frontmatter `deferred` for a future revision of Decision 2.4 to weigh.
  - `[false]` `[reject]` (Edge Case Hunter) `ordinal` passed as 0 or negative silently collapses to no-suffix, masking a caller counting bug — no realistic caller (the not-yet-built `VaultWriter`) would ever construct an ordinal outside its own counting loop starting at 2; matches this epic's "trust the caller" boundary.
  - `[false]` `[reject]` (Edge Case Hunter) `captureDate`/`captureTime24h` malformed values flow through unvalidated, unlike sanitized slug sources — these are explicitly caller-pre-resolved per the Boundaries section, the identical trust boundary Story 2.1's `MeetingForFrontmatter.date` field already establishes without being flagged there.
  - `[false]` `[reject]` (Edge Case Hunter) Hard-cut truncation branch "contradicts" the never-cut-mid-word acceptance criterion — refuted: Decision 2.4's own text explicitly sanctions this exact fallback ("if no hyphen found within 60 chars, hard-cut at 60"); the AC's "never mid-word" applies to the primary hyphen-found path, not this explicitly-documented exception.
  - `[false]` `[reject]` (Verification Gap Reviewer) Self-only attendee list "falls through the with- guard undetected" — traced and executed directly: the pre-revert code already produced the correct fallthrough for this exact input; the finding's own disposition was "add a test," not "fix a bug," and its own demonstration was of a hypothetical future regression, not current behavior. Folded into the amended I/O matrix's new row.
  - `[false]` `[reject]` (Verification Gap Reviewer) Hard-cut truncation branch (no hyphen in the 60-char window) never exercised by any test — real test-coverage gap, not a bug (behavior confirmed correct by direct execution); folded into the amended I/O matrix's two new 60/61-character rows.
  - `[false]` `[reject]` (Intent Alignment Auditor) Work is staged but not yet committed, diverging from the "Story 2.1 is done and committed" precedent — not a defect: commit happens at Finalize, after review completes, identical to how Story 2.1's own iteration was structured.
  - `[false]` `[reject]` (Intent Alignment Auditor) The collision-handling AC is satisfied "in letter, not substantive write-time behavior," since detection is `VaultWriter`'s job — confirms, rather than contradicts, this spec's own explicit Boundaries decision (collision detection is out of scope for this story by design, per Decision 2.4 and the epic context's story-independence framing).
  - `[false]` `[reject]` (Intent Alignment Auditor) `MeetingForFilename` takes pre-formatted `captureDate`/`captureTime24h` strings rather than a raw `capture_started_at` timestamp, narrower than the AC's literal input framing — deliberate, precedented (identical pattern to Story 2.1's `MeetingForFrontmatter.date`), already documented in this spec's Boundaries and Design Notes.
  - `[false]` `[reject]` (Intent Alignment Auditor) No artifact shows a blocked/readiness check ran before implementation — not a defect: the gate is the cascading HALT conditions built into every workflow step, all of which ran and passed.

### 2026-09-16 — Review pass 2
- verdicts: 20 findings — high 0, medium 0, low 0, false 17, maybe-false 0 (3 findings route to `bad_spec`, all sharing one root cause — not counted in the false/verified tally)
- findings:
  - `[bad_spec]` (Blind Hunter) `attendeeSlug` never re-caps the assembled `with-...` slug at 60 characters after joining per-name-normalized pieces — verified by direct execution: two realistic long names produced a 95-character slug. Root cause: iteration 1's Design Notes said "no second normalization pass over the joined string," which correctly ruled out re-running NFKD/ASCII/lowercase/kebab but incorrectly also skipped truncation, a property of the whole assembled string. Amended (see Spec Change Log, pass 2).
  - `[bad_spec]` (Edge Case Hunter, same root cause, high-confidence claim) AC5's "resolved slug never exceeds 60 characters" is violated by the assembled source-2 slug — same defect as above, verified independently; grouped into the same amendment.
  - `[bad_spec]` (Verification Gap Reviewer, same root cause) Confirmed the 60-char cap isn't enforced on the assembled multi-attendee slug via a standalone reproduction (two 60-char names → 130-char slug); disposition and evidence match the two findings above exactly.
  - `[false]` `[reject]` (Blind Hunter) `attendeeSlug` normalizes/truncates each attendee name individually but never re-truncates the assembled result — this is the same finding as the bad_spec entries above, listed once there; not double-counted.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) Design Notes contains two directly contradictory paragraphs about the chosen source-2 algorithm (one arguing for whole-blob normalization, a later one saying it was replaced) — verified: iteration 1's amendment added the corrected paragraph without removing the superseded one. Fixed by deleting the stale paragraph entirely as part of the same re-derivation pass (see Spec Change Log).
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) Code Map cites `Package.swift:141` for the `PersistTests` target; the actual current line is 146 (shifted by Story 2.1's Yams addition) — verified against the live file. Fixed by dropping the specific line number in favor of a description that won't drift.
  - `[false]` `[reject]` (Blind Hunter) Decision 2.4's own "Example filenames" table looks internally contradictory — the "Standard 1:1 with Ben, calendar match" row (`tuesday-sync-with-ben.md`) looks like title+attendee concatenation, seemingly at odds with the strict either/or priority-chain algorithm. Refuted by re-reading in context: this row is consistent with slug source 1 (calendar title) winning outright on a calendar event whose *own* title literally happens to be "Tuesday Sync with Ben" (ordinary text a person or calendar app gave the event) — not a demonstration of the algorithm concatenating title and attendee data. The other three "Example filenames" rows (`project-kickoff.md`, `meeting-at-1030.md`, `with-ben.md`) are all consistent with the strict fallback-chain reading with no exceptions.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) `slug(for:)`'s time-of-day branch has a vacuous `if !timeOfDaySlug.isEmpty` conditional that can never be false — verified by inspection (the `"meeting-at-"` literal prefix alone guarantees non-emptiness). Fixed by removing the dead conditional in the same re-derivation pass.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) No test distinguishes `calendarEventTitle: ""` from `calendarEventTitle: nil` — real gap (both are realistic, and the code path differs even though the outcome is currently identical); added as a new I/O-matrix row.
  - `[false]` `[reject]` (Blind Hunter) Source 4 (id-prefix fallback) bypasses the shared normalize/truncate pipeline and has no test coverage of any kind — reaffirms pass 1's verdict: this branch is proven unreachable via the public API, matching the accepted precedent from Story 2.1's own unreachable defensive branch.
  - `[false]` `[reject]` (Blind Hunter) Slugs ending in digits (e.g. `"q3-2026"`) create ordinal-suffix ambiguity for a future filename parser — rests on an incorrect assumption about `VaultWriter`'s design: Decision 2.4 describes collision handling as incrementally trying `resolve(ordinal: 2)`, `resolve(ordinal: 3)`, ... and checking filesystem existence at each candidate, never parsing an existing filename's trailing characters back into slug/ordinal components. No such parsing need exists in the documented design.
  - `[false]` `[reject]` (Edge Case Hunter) `captureDate`/`captureTime24h` should be validated with a precondition against malformed input — matches the established "trust the caller's pre-resolved input" boundary this epic uses throughout (Story 2.1's `MeetingForFrontmatter.date` is held to the identical standard).
  - `[false]` `[reject]` (Edge Case Hunter) Duplicate attendee entries aren't de-duplicated — no demonstrated realistic path produces them; reaffirms pass 1's verdict.
  - `[false]` `[reject]` (Edge Case Hunter, claim) 3 attendees with self unmatched wrongly expected to join as `with-a-and-b-and-c` — the reviewer's own cited evidence (a passing test asserting fallthrough) confirms this was already fixed in iteration 1; not a live defect.
  - `[false]` `[reject]` (Edge Case Hunter, claim, medium confidence) Hard-cut truncation can split a single long hyphen-free word mid-word — reaffirms pass 1's verdict: this is Decision 2.4's own explicitly documented fallback, not a deviation from it.
  - `[false]` `[reject]` (Intent Alignment Auditor) "If story 2.2 comes back blocked, stop and report" should have governed the pass-1 spec correction (i.e., halting instead of self-amending) — the reviewer has no visibility into this workflow's own bad_spec protocol, which exists precisely to handle a spec error caught in review via revert-amend-re-derive; this is the sanctioned mechanism, not a deviation requiring a halt.
  - `[false]` `[reject]` (Intent Alignment Auditor) The shipped ≤2-post-filter-names rule is stricter than Decision 2.4's literal "≤3 attendees" text — reaffirms pass 1's bad_spec resolution: the "≤3" text describes total headcount as a *consequence* of the 2-name template (self + 2 others = 3), not an independent rule; the corrected behavior is the one consistent with the documented 2-slot `with-<a>-and-<b>` template.
  - `[false]` `[reject]` (Intent Alignment Auditor) Local-time date/time derivation (the one behavior the intent's source docs call out as notable) is entirely untested by this diff, deferred to a future caller — reaffirms pass 1: deliberate, precedented "pre-resolved by caller" boundary, matching `MeetingForFrontmatter.date`.
  - `[false]` `[reject]` (Intent Alignment Auditor) The collision-handling AC's write-time phrasing isn't implemented or tested here — the auditor's own analysis calls this "well-grounded and not a real defect" per the epic context's explicit story-independence framing; recorded for completeness only.
  - `[false]` `[reject]` (Intent Alignment Auditor) Work is staged, not committed, diverging from the "done and committed" precedent — reaffirms pass 1: commit happens at Finalize, after review completes.

### 2026-09-16 — Review pass 3
- verdicts: 16 findings — high 0, medium 0, low 0, false 12, maybe-false 0 (2 findings route to `bad_spec` sharing one root cause, 2 route to `defer` or a direct spec fix without a severity verdict — not counted in the false/verified tally)
- findings:
  - `[bad_spec]` (Blind Hunter) `attendeeSlug`'s final `truncate(joined)` pass can collapse the whole slug to the bare word `"with"` when the only hyphen in the joined string's first 60 characters is the one right after `with-` — verified by direct execution (a single 58-character hyphen-free attendee name → `"...-with.md"`). Root cause: iteration 2's Design Notes treated "re-run truncate() over the joined string" as sufficient, not accounting for where the hyphen-boundary rule would land on a name with no internal separator. Amended (see Spec Change Log, pass 3): each name now capped at 25 characters before joining, so the assembled result can never exceed 60 by construction.
  - `[bad_spec]` (Edge Case Hunter, same root cause, high-confidence claim) Same defect independently found and reproduced; grouped into the same amendment.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) No test for the case where exactly one of two candidate attendee names normalizes to empty (verified the existing code already handles it correctly — `with-ben` — a real coverage gap, not a bug). Added as a new I/O-matrix row.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) This spec's own Tasks & Acceptance AC bullets still described the pre-iteration-1 gating rule (`meeting.attendees.count <= 3`/`> 3`) two amendments after Boundaries and Design Notes were corrected — verified by direct inspection of this file. Rewritten to match the actual post-filter-count rule.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter and Edge Case Hunter, same finding) The Tasks section's stated test count ("20 tests") had drifted from the actual I/O-matrix row count — verified by counting table rows directly (19 at the time of the finding). Replaced with an instruction to count rows directly rather than restate a number that has now drifted twice.
  - `[defer]` (Blind Hunter) Non-ASCII dash punctuation (en dash, em dash) has no NFKD decomposition and gets stripped rather than treated as a word separator, merging adjacent words — not caused by this diff (same architectural root as the already-deferred ß/æ/œ item: Decision 2.4 mandates unconditional non-ASCII stripping). Added as a second frontmatter `deferred` item.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) The spec's Verification section listed only `swift build`/`swift test`, omitting the `swiftformat`/`swiftlint` commands this agent has actually been running as part of its own verification throughout this story — added explicitly, with a note that the repo's full `scripts/check.sh` (release build + Xcode project builds) is a broader, out-of-scope pre-push gate.
  - `[false]` `[reject]` (Blind Hunter) `idPrefixSlug` and other `private` functions are "directly callable from tests without going through the public API" because the test file uses `@testable import Persist` — refuted: `@testable import` elevates `internal` access to test-visible, but does not affect `private`/`fileprivate` declarations, which remain scoped to their own file regardless. `idPrefixSlug` is declared `private`, so it remains genuinely untestable except through `resolve()`'s public surface, which the code already correctly proves cannot reach it.
  - `[false]` `[reject]` (Blind Hunter) Attendee array order isn't guaranteed stable, so the same meeting could resolve to `with-ben-and-chris` one time and `with-chris-and-ben` another if a future caller's data source doesn't guarantee order — this function is 100% deterministic for a given input array; whether repeated calls for "the same meeting" receive the same array order is entirely a property of a caller that doesn't exist yet (`PersistStage`, Story 2.4), matching this epic's established "trust the caller's pre-resolved input" boundary throughout.
  - `[false]` `[reject]` (Blind Hunter) The spec's Design Notes still embeds a verbatim copy of `MeetingForFilename.swift`'s source, which will drift — reaffirms pass 1's verdict: this workflow's own triage rules exclude findings whose only fix is editing this build's spec from patch/bad_spec handling.
  - `[false]` `[reject]` (Blind Hunter) Source 4's id-prefix fallback uses the ULID's leading 8 characters (the timestamp-derived portion) rather than a suffix (the random portion), which would weaken the fallback's collision-resistance exactly when nearby-in-time meetings need it most — a real code-quality observation, but about a branch proven unreachable via the public API today (source 3 always succeeds); reaffirms the precedent from passes 1 and 2 of not requiring fixes to genuinely dead defensive code.
  - `[false]` `[reject]` (Edge Case Hunter) `ordinal` passed as 0 or negative silently collapses to no-suffix — reaffirms passes 1 and 2: no realistic caller constructs an out-of-range ordinal; matches the established trust boundary.
  - `[false]` `[reject]` (Edge Case Hunter, claim) Spec text at the time of the finding still described `meeting.attendees.count <= 3`/`> 3` gating, which a reader could expect to produce `with-a-and-b-and-c` for 3 attendees — this is the same AC-staleness finding Blind Hunter raised, addressed by the same fix (rewriting the AC bullets); not a code defect, and the shipped code has used the corrected post-filter-count rule since iteration 1.
  - `[false]` `[reject]` (Verification Gap Reviewer) No verification gaps found — clean pass, no findings to triage.
  - `[false]` `[reject]` (Intent Alignment Auditor) Local-timezone `capture_started_at` derivation is the one behavior the source docs call out as notable, yet is untested/unimplemented here, deferred to a future caller — reaffirms passes 1 and 2: deliberate, precedented "pre-resolved by caller" boundary matching `MeetingForFrontmatter.date`.
  - `[false]` `[reject]` (Intent Alignment Auditor) The collision-handling AC's write-time framing isn't implemented or tested by this pure-formatting diff — reaffirms passes 1 and 2: well-grounded per the epic context's explicit story-independence framing, not a defect.
  - `[false]` `[reject]` (Intent Alignment Auditor) Work is staged, not committed; the spec artifact's size and self-review process is a materially different kind of deliverable than the four-sentence task text names — observational, not a defect: commit happens at Finalize (reaffirms passes 1 and 2), and the multi-round review process is this workflow's own explicit, sanctioned mechanism (reaffirms pass 2's response to the same category of concern).

### 2026-09-16 — Review pass 4
- verdicts: 20 findings — high 0, medium 0, low 0, false 20, maybe-false 0
- findings:
  - `[false]` `[reject]` (Blind Hunter) `idPrefixSlug` is dead code, risking a strict-lint unused-declaration violation the Verification section doesn't account for — verified: `swiftlint lint --strict .` passed 0 violations with this exact code present (checked directly), so no such rule fires here; reaffirms the precedent (passes 1-3) that this branch's unreachability is accepted, documented, and doesn't need forced coverage.
  - `[false]` `[reject]` (Blind Hunter) Design Notes' "Verified normalization outputs" quick-reference list still frames `"with-Ben"`/`"with-Ben-and-Jordan Whitfield"` as whole-string inputs, a stale mental model from the iteration-1 algorithm — the numeric values are still correct (each name normalizes to the same result individually), only the framing is dated; fix is to edit this build's spec with no behavioral implication, excluded from patch/bad_spec handling per the same rule applied in pass 1 (BH8).
  - `[false]` `[reject]` (Blind Hunter) The "Golden fixture for the plain-ASCII happy path" example's `attendees: ["[[Ben]]"]` doesn't match the shipped test's default `attendees: []` — verified this has no behavioral effect (source 1, calendar title, wins outright regardless of attendees content in this scenario); cosmetic spec-example mismatch, same exclusion as above.
  - `[false]` `[reject]` (Blind Hunter) No test drives `normalize()` to empty via ASCII-only punctuation (e.g. `"!!!"`) rather than non-ASCII stripping — verified by direct execution: `calendarEventTitle: "!!! --- ???"` correctly falls through to `"meeting-at-1423"`. Confirmed correct, not just untested; not pursued further given no bug is demonstrated.
  - `[false]` `[reject]` (Blind Hunter) The 60-char invariant (`with-` + 25 + `-and-` + 25 = 60) depends on four values agreeing with no derived constant tying them together, a future-fragility risk — a legitimate hardening suggestion, but not a current defect (the values are correct today); no wrong behavior demonstrated.
  - `[false]` `[reject]` (Blind Hunter) `if let attendeeSlug = attendeeSlug(for: meeting)` shadows the function name with a local constant — legal Swift, a pure style nit with no behavioral implication and no corresponding project convention violated.
  - `[false]` `[reject]` (Blind Hunter) Uncertain whether the new Swift files are wired into the Xcode project vs. relying on SPM auto-globbing — this repo's targets are SPM-defined and the Xcode project is Tuist-generated from `Package.swift`/project config (per `scripts/check.sh`'s `tuist generate` step); no manual per-file Xcode membership exists to be missing.
  - `[false]` `[reject]` (Blind Hunter) No test covers NFKD-compatibility-decomposable non-Latin characters (e.g. fullwidth Latin letters) that transliterate to ASCII rather than strip — a reasonable additional case, but the same code path already correctly handles the tested accented-Latin case (`"Café"`), so no distinct risk is demonstrated.
  - `[false]` `[reject]` (Blind Hunter) A 310-line internal review log is committed as a permanent versioned artifact — matches this workflow's own explicit, established convention (Story 2.1 did the same; `bmad-build-auto`'s own Finalize step directs committing the spec file), not a deviation this story introduced.
  - `[false]` `[reject]` (Edge Case Hunter) `captureDate` interpolated unsanitized, risking a `/`-bearing value nesting the write into unintended directories — reaffirms the established "trust the caller's pre-resolved input" boundary (passes 1-3); `captureDate` is explicitly documented as already-formatted `"YYYY-MM-DD"`, caller-guaranteed.
  - `[false]` `[reject]` (Edge Case Hunter) Empty `captureTime24h` produces a bare trailing-hyphen filename (`meeting-at-.md`) — verified by direct execution; requires violating the explicit caller contract (`captureTime24h` is documented as already-formatted 4-digit `"HHMM"`), the same trust boundary applied throughout this epic.
  - `[false]` `[reject]` (Edge Case Hunter) Duplicate attendee entries for the same person (e.g. 3x the same wikilink) fall through instead of joining, losing the one real name — reaffirms the precedent from passes 1-3: no demonstrated realistic path produces duplicate entries from a legitimate upstream data source; caller-data-quality, not this function's concern.
  - `[false]` `[reject]` (Edge Case Hunter) A short-word-then-one-long-unbroken-run name (e.g. `"J Middletonwentworth..."`) truncates to just the short word (`"with-j"`) — verified by direct execution. This is the same class of finding rejected in pass 1 (`BH7`): Decision 2.4's own hyphen-boundary truncation rule, applied faithfully, has this as an inherent, acknowledged trade-off of "never cut mid-word" — distinct in kind from the `with`-collapse bug fixed in pass 3, which was caused by this implementation's own connective glue text being mistaken for a name boundary, not by a real name's own structure. No minimum length was ever specified in any source document; inventing one now would be an arbitrary, unspecified threshold.
  - `[false]` `[reject]` (Edge Case Hunter, claim) Empty `captureTime24h` produces a malformed slug, contradicting the "never empty or malformed" AC — same finding as above, same disposition.
  - `[false]` `[reject]` (Edge Case Hunter, claim, low confidence) Source 4 is dead code relative to the "4-source priority chain" task description — reaffirms the precedent from all three prior passes.
  - `[false]` `[reject]` (Verification Gap Reviewer) No verification gaps found — clean pass, nothing to triage.
  - `[false]` `[reject]` (Intent Alignment Auditor) Local-timezone derivation is untested/unimplemented, deferred to a future caller — reaffirms passes 1-3.
  - `[false]` `[reject]` (Intent Alignment Auditor) Collision handling's write-time AC framing isn't implemented or tested by this pure-formatting diff — reaffirms passes 1-3.
  - `[false]` `[reject]` (Intent Alignment Auditor) The "≤3 attendees" source-document ambiguity is resolved in the shipped code but not in `epics.md`/`architecture.md` themselves — accurate observation, but updating those planning documents is outside this story's scope (Story 2.2 implements against them, it doesn't amend them); the shipped resolution is the one consistent with the documented 2-slot `with-<a>-and-<b>` template, per passes 1-3's reasoning.
  - `[false]` `[reject]` (Intent Alignment Auditor) "Blocked" vs. "bad_spec self-correction" is asserted only from inside the same process being audited, not confirmed by an external workflow-definition document — the workflow definition is this skill's own `workflow.md`/`step-04-review.md`, external to and authoritative over any single story's spec artifact; the auditor's review scope (the diff only) doesn't include those files, but they do exist and do define this distinction, reaffirming passes 2-3's response to the same concern.

## Design Notes

**`MeetingForFilename` field list:**

```swift
public struct MeetingForFilename: Sendable, Equatable {
    public let meetingID: MeetingID
    /// Already formatted "YYYY-MM-DD", local time at capture, caller-resolved.
    public let captureDate: String
    /// Already formatted 24h "HHMM" (e.g. "0930", "1423"), local time at capture, caller-resolved.
    public let captureTime24h: String
    public let calendarEventTitle: String?
    /// Wikilink-formatted, e.g. "[[Ben]]" — includes self if self was a named participant.
    public let attendees: [String]
    /// Wikilink-formatted, e.g. "[[Jordan]]" — the config value described in epics.md's
    /// UX-DR42/FR58 (`self.wikilink`). Compared against `attendees` entries by exact string
    /// equality to identify which attendee to omit from the `with-...` slug.
    public let selfWikilink: String?

    public init(
        meetingID: MeetingID,
        captureDate: String,
        captureTime24h: String,
        calendarEventTitle: String?,
        attendees: [String],
        selfWikilink: String?,
    ) {
        self.meetingID = meetingID
        self.captureDate = captureDate
        self.captureTime24h = captureTime24h
        self.calendarEventTitle = calendarEventTitle
        self.attendees = attendees
        self.selfWikilink = selfWikilink
    }
}
```

**Why source 4 (id-prefix) has no forced test:** source 3's candidate string is `"meeting-at-\(meeting.captureTime24h)"`, returned directly without a second normalize pass (it's already a fixed-format ASCII string by construction). It can never be empty for a reason independent of what `captureTime24h` actually contains: the literal prefix `"meeting-at-"` alone is 11 non-empty characters, so the emptiness check guarding the fall-through to source 4 can never trigger. Decision 2.4 itself calls source 4 "defensive only; should be unreachable in practice," and Story 2.2's own AC test-coverage list (epics.md:1215) never names it as required coverage. It's implemented for completeness (a real fallback exists if the priority chain is ever extended), not exercised by a contrived test that would need to force a state the code proves is unreachable.

**Source 2's exact algorithm** (corrected three times in review — see the Spec Change Log for what each iteration fixed and why the current shape avoids re-opening the same class of bug):

1. Filter `meeting.attendees` to remove any entry equal to `meeting.selfWikilink` (exact string equality).
2. Normalize **each remaining name individually** through the full `normalize()` pipeline (NFKD → strip-non-ASCII → lowercase → kebab-case → trim), but with the length cap set to **25 characters** for this step, not 60 — see below for where 25 comes from — then discard any name that normalizes to empty.
3. If the surviving list has 0, or more than 2, names, this source does not apply — fall through to source 3.
4. If 1 or 2 names survive, join them with `-and-` and prefix `with-`. **Return this directly — no further truncation pass over the assembled string.**

**Where 25 comes from, and why capping each name before joining (not truncating the assembled result after) is the correct shape:** the budget for the *whole* assembled slug is 60 characters. The glue text is fixed and known in advance: `with-` is 5 characters, and (in the 2-name case) `-and-` is another 5 — worst case, non-glue budget is `60 - 5 - 5 = 50` characters split across 2 names, i.e. 25 each. Capping each name at 25 *before* joining guarantees the assembled result can never exceed 60 (1-name case: `5 + 25 = 30`, well under; 2-name case: `5 + 25 + 5 + 25 = 60` exactly) — by construction, with no second pass needed. This replaces iteration 2's approach (join at full per-name length, then run the *assembled* string through `truncate()`), which had a sharper bug: `truncate()`'s hyphen-boundary rule finds the *last* hyphen at-or-before character 60, and for a single long hyphen-free name, the only hyphen in that window can be the one right after `with-` itself — collapsing the result to the bare word `with` with zero attendee-name content, strictly worse than iteration 1's `with-and` bug. Capping *before* joining sidesteps this failure mode entirely: even a 30+ character hyphen-free single-word name now hard-cuts to a 25-character fragment of itself (via the same hyphen-boundary-or-hard-cut rule, just with a smaller limit) — real content, not a glue-word husk.

**Also fix while re-deriving (found in the same review pass, small and mechanical):** `slug(for:)`'s time-of-day branch (`let timeOfDaySlug = "..."; if !timeOfDaySlug.isEmpty { return timeOfDaySlug }`) is a vacuous conditional — the string can never be empty (see the fallback-4 rationale below), so the `if` guards nothing and should just be `return timeOfDaySlug` directly, with the non-emptiness explained in a comment rather than checked in a dead branch.

**Golden fixture for the plain-ASCII happy path** (the literal string the first test should assert against):

```
FilenameResolver.resolve(meeting: MeetingForFilename(
    meetingID: MeetingID(ulid: "01HJK3PQXY7N8M3FT4QHNWVZRP")!,
    captureDate: "2026-04-28",
    captureTime24h: "1000",
    calendarEventTitle: "Tuesday Sync",
    attendees: ["[[Ben]]"],
    selfWikilink: nil,
)) == "2026-04-28-tuesday-sync.md"
```

**Verified normalization outputs** (computed directly, not hand-derived, to avoid a wrong golden value — reproduce with any NFKD-based pipeline matching the 8 steps above):
- `"Café résumé"` → `"cafe-resume"`
- `"北京会议"` → `""` (falls through)
- `"🎉 Launch!"` → `"launch"`
- `"🎉🎉🎉"` → `""` (falls through)
- `"This is an extremely long meeting title that exceeds the slug length cap"` → `"this-is-an-extremely-long-meeting-title-that-exceeds-the"` (56 chars, truncated at the last hyphen ≤60)
- `"with-Ben"` → `"with-ben"`
- `"with-Ben-and-Jordan Whitfield"` → `"with-ben-and-jordan-whitfield"`

## Verification

**Commands:**
- `swift test --filter PersistTests` -- expected: all `FilenameResolverTests` pass alongside the existing `FrontmatterRendererTests`.
- `swift build` -- expected: clean build (no new external dependency — Foundation's NFKD API is sufficient).
- `swiftformat --lint .` and `swiftlint lint --strict .` (via the repo's pinned mise-managed toolchain) -- expected: 0 violations. `scripts/check.sh` runs these plus a full release build and Xcode project checks; that broader pre-push gate is out of scope for a single story's own verification, but these two fast commands specifically are worth running here since they're what CI (and the repo's pre-commit hook) actually enforce.

## Auto Run Result

**Summary:** Implemented `Persist/FilenameResolver.swift` and its input type `Persist/MeetingForFilename.swift`, computing the deterministic `<date>-<slug>.md` filename per Decision 2.4's 4-source priority chain (calendar title → named attendees → time-of-day → id-prefix) and 8-step normalization pipeline. Three full review-driven spec-correction cycles were needed before the algorithm was correct — each is documented in detail in the Spec Change Log and Review Triage Log above, not repeated here.

**Files changed:**
- `Sources/Persist/MeetingForFilename.swift` -- new. The resolver's sole input type.
- `Sources/Persist/FilenameResolver.swift` -- new. `FilenameResolver.resolve(meeting:ordinal:) -> String`, the pure priority-chain/normalization function.
- `Tests/PersistTests/FilenameResolverTests.swift` -- new, one `@Test` per I/O-matrix row (21 tests as of the final iteration).

**Review findings breakdown across 4 review passes** (full detail, including every rejected finding's reasoning, is in the Review Triage Log above; summarized here):
- **Pass 1 → bad_spec (2 findings, 1 root cause):** the originally-specified source-2 algorithm joined all 3 non-self names when self wasn't identifiable (exceeding the documented 2-name template) and produced a meaningless `with-and` slug when every attendee name normalized to empty. Fixed by normalizing each attendee name individually and gating on the post-filter survivor count.
- **Pass 2 → bad_spec (3 findings, 1 root cause):** the pass-1 fix didn't re-cap the *assembled* joined slug, so two individually-short-enough names could combine past 60 characters. Fixed by re-running the truncation step (not the full pipeline) over the joined string. This same pass also fixed a stale Code Map line reference and a vacuous conditional, as direct spec/code cleanups (outside intent-contract, no revert needed for those two).
- **Pass 3 → bad_spec (2 findings, 1 root cause):** the pass-2 fix had a sharper bug — the re-truncation could land on the hyphen right after the literal `with-` glue text for a single long hyphen-free name, collapsing the entire slug to the bare word `"with"` (worse than the original bug: zero attendee identity survived). Fixed with a structurally-different approach: cap each attendee name at 25 characters *before* joining (a budget derived from the fixed glue-text lengths), guaranteeing the 60-char cap holds by construction with no fragile second truncation pass. This pass also fixed genuinely stale AC text (still describing the pre-pass-1 gating rule two amendments later), a drifting test-count reference, and added `swiftformat`/`swiftlint` to the Verification section.
- **Pass 4 → clean (20 findings, all rejected):** every finding was either empirically refuted (verified directly against the running code — a punctuation-only calendar title, an empty `captureTime24h`, and a short-prefix-then-long-run attendee name were all traced and executed to confirm correct or intentionally-accepted behavior) or reaffirmed a precedent already established in passes 1-3 (trust-the-caller boundaries, unreachable source-4 dead code, spec-only documentation nits excluded from patch/bad_spec handling, and the process-level questions about commit timing and the bad_spec self-correction mechanism itself).
- **Deferred (2 items, added to frontmatter `deferred:`):** NFKD's inability to transliterate ß/æ/œ, and non-ASCII dash punctuation (en/em dash) being deleted rather than treated as a word separator — both inherited directly from Decision 2.4's own mandated "strip all non-ASCII" algorithm, not defects this story's implementation introduces.

**Follow-up review recommendation: `false`.** The final review pass (pass 4) patched nothing — every finding was rejected on its merits, either by direct empirical refutation or by reaffirming settled precedent from the three prior passes. No unverified risk remains to name.

**Verification performed:** `swift build` and `swift test --filter PersistTests` run after every one of the four implementation/re-derivation cycles (final: 21/21 `FilenameResolverTests` pass, 33/33 `PersistTests`, 154/154 full suite); `swiftformat --lint .` and `swiftlint lint --strict .` (repo-wide, via the pinned mise toolchain) clean at every checkpoint. Beyond the spec's own listed commands, this agent additionally ran targeted empirical probes (throwaway test files, removed before each commit) at every review pass to directly execute the exact scenario each reviewer described, rather than judging plausibility from code-reading alone — this is what caught all three real bugs (the pass-1, pass-2, and pass-3 root causes) and what refuted several pass-4 findings that turned out to already be correct.

**Residual risks:** the two deferred items above (ß/æ/œ and non-ASCII dash handling, both inherited from Decision 2.4's mandated algorithm); the accepted trade-off that a pathological short-word-then-long-unbroken-run name truncates to just the short word (Decision 2.4's own hyphen-boundary rule, not something this story's implementation can safely deviate from without inventing an unspecified minimum-length threshold); and the standing caller-trust boundary this whole epic uses throughout (`captureDate`/`captureTime24h`/attendee list contents are assumed pre-resolved and well-formed, not defended against malformed input).
