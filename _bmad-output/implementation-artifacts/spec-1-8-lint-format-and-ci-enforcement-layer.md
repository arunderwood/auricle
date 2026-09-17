---
title: "Story 1.8: Lint, Format, and CI Enforcement Layer"
type: 'feature'
created: '2026-09-16'
status: 'done'
baseline_revision: '1221202e8a7a1831504d1bcdfdbb264046ed1ab0'
review_loop_iteration: 0
followup_review_recommended: true
context: ['{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md']
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** No `.swiftformat`, `.swiftlint.yml`, or `.github/workflows/ci.yml` exist yet, so architecture.md's naming/JSON-dialect/10-primitive helper-bypass rules, `Package.swift`'s own flagged `--explicit-target-dependency-import-check` gap, and the `Auricle.xcodeproj`/`tuist generate` cleanliness invariants are enforced by nothing but human review — the same kind of regression Story 1.7 already hit once (a silently wrong `productName`).

**Approach:** Add root `.swiftformat` + `.swiftlint.yml` (default naming/layout rules plus 6 new `custom_rules`: 5 helper-bypass greps per the AC + 1 accessibilityLabel check) and `.github/workflows/ci.yml` running the full gate chain in one uncached, `pull_request`-triggered job.

## Boundaries & Constraints

**Always:**
- 5 helper-bypass `custom_rules` match the AC's literal patterns, each `excluded` from its one legitimate owner file: `AtomicWriter.swift` (`Data.write(to:`, `FileManager.createFile`), `Log.swift` (`os_log(`), the composition roots `AuricleApp.swift`/`AuricleCLI.swift`/`Tests/TestSupport/TestComposition.swift` (concrete-strategy instantiation), `StageEventLogger.swift`/`TelemetryRecorder.swift` (`INSERT INTO stage_events` / `INSERT INTO telemetry`).
- Wire `swift build --explicit-target-dependency-import-check error` into CI per `Package.swift:1-6`'s own comment.
- Add `swift build -c release` as its own CI step — `deferred-work.md:41-43` names Story 1.8 the explicit scope owner of automating this exact command, already accepted as sufficient verification during Story 1.3's review.
- CI fails on a git-tracked `App/Auricle.xcodeproj` and on a dirty `git status --porcelain` after `tuist generate` (both explicit AC lines).
- One job, one clean checkout, no `actions/cache`.
- Ship `Sources/TestSupport/MarkdownDisciplineChecker.swift`, a renderer-independent AR-PAT-9 validator (markdown string in, violations out) plus a unit test — the "runner infrastructure" the AC asks for now, callable by Epic 2's `FrontmatterRendererTests.swift` later without this story needing a renderer to exist.

**Never:**
- Don't touch `sprint-status.yaml` (documented repo pitfall, out of this story's scope).
- Don't automate the Codable round-trip-test check — the AC and architecture.md both mark it human/code-review-enforced, not tooling-enforced.
- Don't add GitHub Actions build-artifact caching (explicit AC line).
- Don't wire a markdown-discipline CI *job* against real renderer output — Epic 2 doesn't exist yet; ship only the checker utility.
- Don't touch `PermissionChecker`/`DesignTokens` lint rules — future epics' concern.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Helper-bypass call outside its owner file | e.g. `Data.write(to:)` added in a stage file | `swiftlint` fails with the custom rule's message | CI job red, PR blocked |
| Same call inside its legitimate owner file | e.g. `Data.write(to:)` inside `AtomicWriter.swift` | `swiftlint` passes | No error |
| `App/Auricle.xcodeproj` accidentally tracked | `git ls-files` lists it | CI step explicitly fails, naming the file | CI job red |
| `tuist generate` leaves stray diffs outside `.gitignore` | dirty `git status --porcelain` post-generate | CI step fails, printing the diff | CI job red |
| Clean PR, no violations | typical story diff | full gate chain passes | CI job green |

</intent-contract>

## Code Map

- `mise.toml` -- already pins `tuist 4.208.0` / `swiftformat 0.63.0` / `swiftlint 0.65.1` (AR-INIT-6) -- CI runs `mise install` then invokes these exact pinned versions, no separate install step
- `Package.swift:1-6` -- comment already names the exact flag (`--explicit-target-dependency-import-check error`) this story wires into `swift build`
- `.gitignore:210-231` -- already excludes `App/Auricle.xcodeproj/`, `*.xcodeproj/`, `.build/`, `DerivedData/` -- CI's tracked-file check asserts against this, does not duplicate the ignore list
- `Sources/Core/AtomicWriter.swift` -- sole legitimate site for `Data.write(to:)`/`FileManager.createFile` -- excluded from that custom rule
- `Sources/Core/Log.swift` -- sole legitimate site for `os_log(` -- excluded from that custom rule
- `Sources/Telemetry/StageEventLogger.swift`, `Sources/Telemetry/TelemetryRecorder.swift` -- sole legitimate sites for `INSERT INTO stage_events` / `INSERT INTO telemetry` -- excluded from that custom rule
- `App/Auricle/AuricleApp.swift`, `App/auricle-cli/AuricleCLI.swift` -- the two composition roots that exist today (`Tests/TestSupport/TestComposition.swift` doesn't exist yet but stays pre-excluded per the AC's own list) -- excluded from the concrete-strategy-instantiation rule
- No canonicalization-layer file exists yet (`CanonicalTranscript` deferred past Epic 1, `deferred-work.md:13-15`) -- the transcript-decode custom rule ships with no exclusion list; a future story adds its file there
- `_bmad-output/implementation-artifacts/deferred-work.md:41-43` -- names Story 1.8 the explicit scope owner of a release-config CI build step
- `App/Project.swift`, and spec-1-7's build commands -- exact Tuist scheme names (`AuricleApp`, `auricle-cli`) CI's `xcodebuild -scheme` invocations must match

## Tasks & Acceptance

**Execution:**
- `.swiftformat` -- new: Swift API Design Guidelines layout/spacing config, `--swiftversion 6.3` matching the pinned toolchain
- `.swiftlint.yml` -- new: rely on swiftlint's default naming rules (covers AR-PAT-1) plus 6 `custom_rules` -- 5 helper-bypass greps (scoped per Code Map exclusions above) + 1 best-effort line-level regex flagging `Button(`/`Toggle(`/`TextField(` with no nearby `.accessibilityLabel(` (per UX-DR65)
- `Sources/TestSupport/MarkdownDisciplineChecker.swift` -- new: pure string-in validator for AR-PAT-9 (no `# ` header, no header beyond `### `, no emoji, no horizontal rule outside frontmatter, no table)
- `Tests/CoreTests/MarkdownDisciplineCheckerTests.swift` -- new: one violating case + one clean case per AR-PAT-9 rule
- `.github/workflows/ci.yml` -- new: single `pull_request`-triggered job, one clean runner, no caching; steps in order: `mise install`; `swift build --explicit-target-dependency-import-check error`; `swift build -c release`; `swift test`; `tuist generate --no-open` (from `App/`); `xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp -destination "platform=macOS" build`; same for `-scheme auricle-cli`; `swiftformat --lint .`; `swiftlint`; a tracked-`.xcodeproj` check; a post-`tuist generate` `git status --porcelain` cleanliness check

**Acceptance Criteria:**
- Given `.swiftlint.yml`'s custom rules, when any of the 5 helper-bypass patterns appears outside its owner file, then `swiftlint` exits non-zero
- Given `ci.yml`, when a PR opens, then every listed command runs inside one job with no artifact caching
- Given a `Codable` conformance added without a round-trip test, when CI runs, then nothing automated blocks it (human code-review reject only, per architecture.md and the AC)
- Given Story 1.8 ships, when a later story adds its own CI gate, then it extends `ci.yml` rather than creating a new workflow file

## Spec Change Log

## Review Triage Log

### 2026-09-16 — Review pass
- verdicts: 30 findings — high 1, medium 2, low 16, false 11, maybe-false 0
- findings:
  - `[false]` `[reject]` CI workflow triggers only on `pull_request`, never `push`/`workflow_dispatch` (Blind Hunter) — refuted: epics.md's own AC text scopes the trigger exactly this way ("When a PR opens... Then the workflow runs..."); `on: pull_request` is exact compliance, not an oversight.
  - `[high]` `[patch]` `runs-on: macos-14` paired with `.xcode-version: 26.4.1` (Blind Hunter) — verified: `.xcode-version` confirmed 26.4.1; a Sonoma-era `macos-14` GitHub runner image almost certainly does not ship Xcode 26.x, so `setup-xcode@v1` would fail on the first real CI run, defeating this story's purpose. Action: swapped `runs-on: macos-14` to `runs-on: macos-latest`.
  - `[low]` `[patch]` Tracked-`.xcodeproj` CI check only checks `App/Auricle.xcodeproj` (Blind Hunter) — verified via `.gitignore`'s own pre-existing comment ("`tuist generate` also emits a workspace at the repo root and an `AuricleKit.xcodeproj` preview... same rule applies to those"); the dirty-tree check wouldn't catch an already-tracked, unmodified file either. Action: broadened the check to `git ls-files '*.xcodeproj' '*.xcworkspace'`.
  - `[low]` `[patch]` `--explicit-target-dependency-import-check error` wired only into `swift build`, not `swift test` (Blind Hunter) — verified via `swift test --help`, which lists the identical flag; test-target cross-target imports were unchecked. Action: added the same flag to the `swift test` step.
  - `[low]` `[patch]` `.swiftlint.yml`'s `line_length` comment cites "161 chars" as the tree's longest line (Blind Hunter) — verified via direct scan: actual longest is 169 chars (`Package.swift:82`), 1 char under the 170 warning threshold instead of ~9 as implied. Action: corrected the cited number and raised the threshold for real headroom.
  - `[low]` `[patch]` `composition_root_strategy_bypass` pre-excludes not-yet-created `TestComposition.swift` but not the five not-yet-implemented concrete-strategy source directories (Blind Hunter) — verified: those targets are empty `ManifestPlaceholder.swift` files today; a future internal type sharing a vendor-name prefix would false-positive once real code lands. Action: pre-excluded the five concrete-strategy directories, matching the existing `TestComposition.swift` precedent.
  - `[low]` `[reject]` `accessibility_label_missing` fires even when a `Button`/`Toggle` already carries a title string SwiftUI surfaces to VoiceOver automatically (Blind Hunter) — verified real. Rejected: zero interactive SwiftUI controls exist anywhere in this codebase today, so very unlikely to be met in everyday use for some time, and a correct fix needs real argument parsing, not a direct regex correction.
  - `[low]` `[patch]` `telemetry_sql_bypass` is the only one of the six `custom_rules` missing `match_kinds`, so it also matches inside comments/string literals (Blind Hunter) — verified against its five siblings, all restricted to `identifier`/`keyword`. Action: deliberately deviated from the literal suggestion — `match_kinds: [identifier, keyword]` was probed first and made the rule match nothing at all, including the real violation, because the SQL text only ever appears inside a string-literal token; applied `match_kinds: [string]` instead, verified by probe to still exclude a bare comment while catching the literal.
  - `[low]` `[patch]` `swiftformat --lint`/`swiftlint` run last in `ci.yml`, after both `swift build`s, `swift test`, `tuist generate`, and both `xcodebuild`s (Blind Hunter) — verified by reading step order; a trivial formatting nit pays for the whole expensive chain before failing. Action: moved the lint/format steps immediately after `mise install`.
  - `[low]` `[patch]` No `concurrency:` group in `ci.yml` (Blind Hunter) — verified: a fixup push queues a second full macOS job instead of canceling the superseded one. Action: added a `concurrency` block keyed on the ref with `cancel-in-progress: true`.
  - `[low]` `[patch]` No `timeout-minutes` set on the job (Blind Hunter) — verified: GitHub's default job timeout is 6 hours. Action: added a `timeout-minutes` bound.
  - `[low]` `[patch]` No `permissions:` block narrows the default `GITHUB_TOKEN` (Blind Hunter) — verified absent, a standard hardening gap for an enforcement-focused workflow. Action: added `permissions: contents: read`.
  - `[false]` `[reject]` `MarkdownDisciplineChecker` lives in `TestSupport`, excluded from both app targets, so it can never run at app runtime (Blind Hunter) — refuted: the spec's own Boundaries explicitly scope this as Epic 2 "runner infrastructure" for future snapshot tests, never a runtime validator; `TestSupport` is deliberately excluded from every app target repo-wide, matching every other `TestSupport` addition.
  - `[false]` `[reject]` `xcodebuild` steps build Debug only, with no comment explaining why (Blind Hunter) — refuted: already correct and self-explained (`Release.xcconfig`'s own comment: `CODE_SIGN_IDENTITY` doesn't exist until Story 9.3); this codebase tracks such deferred reasoning centrally in `deferred-work.md`, not via inline comments at every call site.
  - `[low]` `[patch]` `MarkdownDisciplineChecker.headerDepth(of:)` scans for leading `#` only from `line.startIndex`, so a CommonMark-valid ATX heading indented 1-3 spaces is never recognized as a header (Edge Case Hunter) — verified by reading the function: no leading-whitespace trim exists. Action: trim up to 3 leading spaces before counting.
  - `[false]` `[reject]` CRLF input isn't normalized before frontmatter/horizontal-rule detection (Edge Case Hunter) — refuted: architecture.md's Markdown Output pattern mandates LF-only line endings as an invariant of anything the renderer (this checker's only real caller) will ever produce; CRLF is out of scope by the same contract.
  - `[false]` `[reject]` Header/emoji checks run unconditionally inside frontmatter too, unlike the HR/table checks (Edge Case Hunter) — refuted: architecture.md's "no emoji" rule carries no "outside frontmatter" qualifier the HR rule explicitly has, so applying it everywhere is the textually correct reading; the YAML-`#`-comment collision needs a frontmatter line starting with a literal `#`, unreachable given the fixed, programmatically-generated Decision 2.2 schema.
  - `[low]` `[reject]` Multi-scalar grapheme emoji check only inspects `firstScalar.isEmoji`, which could misflag a digit/punctuation combined with an unrelated combining mark (Edge Case Hunter) — verified real and narrow. Rejected: no realistic meeting-transcript scenario produces this, and a correct general fix needs real Unicode grapheme-cluster analysis, not a direct correction.
  - `[low]` `[patch]` `atomic_writer_bypass`'s regex requires the literal `FileManager.` prefix, missing `FileManager().createFile(...)` (Edge Case Hunter) — verified against the regex text. Action: extended the alternation to also match direct instantiation.
  - `[low]` `[reject]` `transcript_decode_bypass` only matches an inline `JSONDecoder().decode(...)` call, missing a stored-decoder-variable pattern (Edge Case Hunter) — verified real. Rejected: no transcript-decoding code exists anywhere in this tree yet, the spec's own Design Notes already flag this rule as provisional pending that future story, and a robust general fix needs broader static analysis than a direct correction.
  - `[low]` `[patch]` `telemetry_sql_bypass`'s regex is case-sensitive, missing a lowercase `insert into` (Edge Case Hunter) — verified against the regex text. Action: made the match case-insensitive.
  - `[low]` `[patch]` `composition_root_strategy_bypass`'s regex only matches a direct call form, missing `TypeName.init(...)` (Edge Case Hunter) — verified against the regex text. Action: extended the regex to also match the `.init(` form.
  - `[false]` `[reject]` Tasks & Acceptance's unqualified "no table" claim reads broader than the implementation's frontmatter-qualified table check (Edge Case Hunter, filed low-confidence) — refuted: frontmatter is a fixed, programmatically-generated YAML block with no path to ever contain GFM table syntax, so the unqualified text and the qualified implementation are behaviorally identical for any reachable input.
  - `[medium]` `[patch]` SwiftLint's six `custom_rules` have no automated check that they actually fire (Verification Gap Reviewer, pre-verified) — the reviewer grepped the whole worktree for every rule's target pattern outside its exclusions, confirmed none exist today, and confirmed `swiftlint lint --strict .` would exit 0 identically whether a rule's regex is correct or silently broken. Action: added a fixture-based CI check feeding one known violation per custom rule through swiftlint and asserting the expected rule id fires.
  - `[false]` `[reject]` Diff contains no evidence the spec's five Verification commands were actually run (Intent Alignment Auditor) — refuted: those commands were independently executed against the real worktree during this run's own step-03 Verify stage (0 swiftlint violations, 0 swiftformat diffs, `swift build`/`swift build -c release`/`swift test` all exit 0 with 119/119 tests passing, both `xcodebuild` schemes `BUILD SUCCEEDED`, clean `git status --porcelain` post-`tuist generate`); a diff is source text and cannot itself contain runtime verification output.
  - `[medium]` `[patch]` Custom lint rules have zero test coverage in the diff (Intent Alignment Auditor) — same root cause and action as the Verification Gap Reviewer's finding above; grouped.
  - `[false]` `[reject]` CI enforcement is inherently unverifiable from a diff since a GitHub Actions run can't appear in a patch (Intent Alignment Auditor) — refuted: a structural property of reviewing any CI-config change by diff, not a defect this story introduced.
  - `[false]` `[reject]` `MarkdownDisciplineCheckerTests.swift` sits in `Tests/CoreTests` while the code it tests lives in the `TestSupport` target (Intent Alignment Auditor) — refuted: `TestSupport` has no test target of its own in `Package.swift` by design (the shared-fixtures target, not a target under test), and `CoreTests` already depends on `TestSupport`, making it the only structurally available, correct home.
  - `[false]` `[reject]` External identifiers cited in the new config comments (AR-PAT-N, NFR-N, Decision N, etc.) aren't verifiable from the diff alone (Intent Alignment Auditor) — refuted: independently verified against `architecture.md` during this run's own planning stage before implementation began; citing external planning docs in rationale comments is normal practice here.
  - `[false]` `[reject]` Reading D ("close out story tracking") is not implemented; `sprint-status.yaml` stays untouched and the spec self-reports `status: 'in-review'` (Intent Alignment Auditor) — refuted: the spec's own Boundaries explicitly exclude this ("Don't touch `sprint-status.yaml`... out of this story's scope"), matching this repo's documented pitfall; an intentional scope match, not a gap.

## Design Notes

- **Why only 6 `custom_rules`:** swiftlint's built-in `identifier_name`/`type_name`/etc. rules already cover AR-PAT-1's naming guidelines out of the box; only the helper-bypass greps and the accessibilityLabel check have no built-in equivalent.
- **Why the accessibilityLabel rule is "best-effort":** SwiftLint `custom_rules` are line-level regex with no SwiftUI-modifier-chain awareness, so this rule has a real, bounded false-negative rate (e.g. a label applied several lines below the control). That matches the AC's "detects" bar without overclaiming soundness a regex-based tool can't provide.
- **Why `swift build -c release` (not a binary-inspection script) closes the deferred-work.md item:** `deferred-work.md:41-43` names that exact command as what was already manually run and accepted as sufficient verification during Story 1.3's review — automating the identical command is what the entry asks for, not a stronger guarantee this story would need to invent.

## Verification

**Commands:**
- `swiftlint lint --strict .` -- expected: 0 violations against the current tree
- `swiftformat --lint .` -- expected: no diffs
- `swift build --explicit-target-dependency-import-check error && swift build -c release && swift test` -- expected: all exit 0
- `cd App && tuist generate --no-open && xcodebuild -project Auricle.xcodeproj -scheme AuricleApp -destination "platform=macOS" build && xcodebuild -project Auricle.xcodeproj -scheme auricle-cli -destination "platform=macOS" build` -- expected: both `BUILD SUCCEEDED`, then `git status --porcelain` from repo root is empty
- Temporarily add a throwaway direct `os_log(` call outside `Log.swift`, run `swiftlint`, confirm it is flagged, then revert -- expected: the custom rule fires (one-time manual sanity check, not part of the automated suite)

## Auto Run Result

**Summary:** Added the lint/format/CI enforcement layer for Epic 1: root `.swiftformat` and `.swiftlint.yml` (default naming rules plus 6 custom rules — 5 helper-bypass greps + 1 accessibilityLabel check), `.github/workflows/ci.yml` running the full gate chain in one job, and `Sources/TestSupport/MarkdownDisciplineChecker.swift` as the AR-PAT-9 "runner infrastructure" for Epic 2's future snapshot tests. A review pass found 30 issues across 4 reviewers; 15 were patched (1 high, 1 grouped-medium, 13 low), 11 were false, 3 low findings were rejected as unlikely-to-hit-with-non-trivial-fix.

**Files changed:**
- `.swiftformat` -- new: Swift API Design Guidelines layout/spacing config
- `.swiftlint.yml` -- new: naming-rule tuning + 6 custom_rules (post-patch: composition-root rule pre-excludes the 5 not-yet-implemented concrete-strategy directories and matches `.init(`; telemetry-SQL rule is case-insensitive with `match_kinds: [string]`; atomic-writer rule also matches `FileManager()` direct instantiation; corrected line-length rationale/threshold)
- `.github/workflows/ci.yml` -- new: single `pull_request` job on `macos-latest` (post-patch, was `macos-14`), `concurrency`/`timeout-minutes`/`permissions` hardening, lint/format moved before the expensive build/test/xcodebuild chain, `--explicit-target-dependency-import-check error` on both `swift build` and `swift test`, a broadened tracked-project/workspace check, and a new fixture self-check step that feeds one known violation per custom rule through swiftlint and asserts every rule id fires
- `Sources/TestSupport/MarkdownDisciplineChecker.swift` -- new: pure AR-PAT-9 markdown-discipline validator (post-patch: `headerDepth` now tolerates up to 3 leading spaces per CommonMark)
- `Tests/CoreTests/MarkdownDisciplineCheckerTests.swift` -- new: 6 unit tests (5 original + 1 added for the indented-header patch)
- `Sources/TestSupport/ManifestPlaceholder.swift` -- deleted, superseded by real source per its own removal condition
- ~52 other tracked `.swift` files -- reformatted by `swiftformat` to establish the baseline (trailing commas, import ordering, `case let` binding style, doc-comment slashes; no behavior change, confirmed by full `swift test` pass before and after)

**Review findings breakdown** (30 findings across Blind Hunter, Edge Case Hunter, Verification Gap Reviewer, Intent Alignment Auditor -- full detail in `## Review Triage Log` above):
- **Patched (15: 1 high, 2 medium as one grouped entry, 13 low):** `macos-14`→`macos-latest` runner/Xcode-version mismatch (high); a fixture self-check so the 6 custom_rules can no longer go silently dead (medium, grouped Verification-Gap + Intent-Alignment); tracked-project check broadened beyond `App/Auricle.xcodeproj`; `--explicit-target-dependency-import-check` added to `swift test`; corrected line-length comment/threshold; pre-excluded the 5 concrete-strategy directories from the composition-root rule; `match_kinds` added to the telemetry-SQL rule (as `[string]`, not the literally-suggested `[identifier, keyword]` -- that combination was probed and found to make the rule match nothing, including the real violation); lint/format steps moved before the expensive build chain; `concurrency`/`timeout-minutes`/`permissions` added to CI; indented-ATX-header handling in `MarkdownDisciplineChecker`; `FileManager()` and `.init(` forms added to two custom-rule regexes; telemetry-SQL regex made case-insensitive.
- **Rejected as low (3):** `accessibility_label_missing` false-positives on an already-labeled `Button("Save")` -- no interactive SwiftUI controls exist anywhere in this codebase yet, and a correct fix needs real argument parsing; multi-scalar-grapheme emoji-detection imprecision -- no realistic transcript scenario produces it, and a general fix needs full Unicode grapheme-cluster analysis; `transcript_decode_bypass`'s inline-only decoder pattern -- no transcript-decoding code exists anywhere yet (`CanonicalTranscript` deferred past Epic 1), already flagged provisional in this spec's own Design Notes.
- **Rejected as false (11, one line each):** CI trigger scope matches the AC's literal "when a PR opens" text; `MarkdownDisciplineChecker`'s TestSupport placement matches the spec's own explicit test-infrastructure framing; Debug-only `xcodebuild` is correct and already explained by `Release.xcconfig`'s own comment; CRLF handling is out of scope per AR-PAT-9's LF-only contract; frontmatter-wide header/emoji checks match AR-PAT-9's unqualified wording; the "no table" AC-text-vs-implementation gap is unreachable given frontmatter's fixed YAML schema; the diff-can't-show-verification-output/CI-run/external-citations/D-not-implemented points from Intent Alignment Auditor are all structural properties of diff-based review or already-covered spec scope, not defects; and the `MarkdownDisciplineCheckerTests.swift` cross-module placement is the only structurally available, already-correct home given `TestSupport` has no test target of its own.

**Follow-up review recommendation:** `true` -- one `high` finding was patched this pass (the `macos-14`/Xcode-26.4.1 runner mismatch). Specific unverified risk: this fix, and the whole `ci.yml` gate chain, has only been verified by extracting and re-running its steps locally -- nothing here can confirm the workflow actually succeeds end-to-end on GitHub's real Actions infrastructure (runner image contents, `mise install` via `curl` in that environment, `setup-xcode@v1` actually resolving Xcode 26.4.1 on `macos-latest`) until a real PR opens and the workflow runs for the first time.

**Verification performed:** All 5 commands in this spec's own `## Verification` section were re-run independently after the patch batch (not just trusted from the implementer's report): `swiftlint lint --strict .` (0 violations, 93 files), `swiftformat --lint .` (0/93 need formatting), `swift build --explicit-target-dependency-import-check error && swift build -c release && swift test --explicit-target-dependency-import-check error` (all exit 0, 120/120 tests pass), `tuist generate --no-open` + both `xcodebuild` schemes (`BUILD SUCCEEDED`) + `git status --porcelain` clean post-generate, and the broadened tracked-project check confirmed empty. Independently re-verified (not just the implementer's report) that all 6 custom_rules fire against a fixture file covering all 6 violations at once, that the case-insensitive SQL match and the `.init(` composition-root match both work via targeted probes, and that no probe/scratch files were left behind.

**Residual risks:** The `ci.yml` workflow has never actually run on GitHub Actions (see follow-up recommendation above). The `accessibility_label_missing` custom rule remains best-effort/line-level by design and will need retuning against real SwiftUI code once Epic 6/7 land the first interactive controls. `transcript_decode_bypass` ships with no exclusion list since no canonicalization-layer file exists yet -- a future story must add one when it lands. `sprint-status.yaml` continues to understate progress across this epic (documented, out of this story's scope).

**Post-PR update (2026-09-16):** The flagged risk above was real. PR #16's first CI run failed within 44s: `mise install` made unauthenticated GitHub releases-API calls and exhausted the runner IP's shared 60/hr limit, so `swiftformat` never installed (`tuist`/`swiftlint` happened to install first and succeeded). Fixed by adding a job-level `env: GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` to `.github/workflows/ci.yml`, giving mise the default token's 5,000/hr authenticated limit -- no extra permissions needed beyond the existing `permissions: contents: read`. Pushed as a follow-up commit on the same PR; watching the re-run to confirm the actual `macos-14`→`macos-latest` and Xcode-resolution fix (this story's originally-flagged high finding) holds once the toolchain-install step gets past this unrelated blocker.
