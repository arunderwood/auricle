---
title: 'VaultWriter — Atomic Write, Path Resolution, Collision Handling'
type: 'feature'
created: '2026-09-16'
status: 'done'
baseline_revision: '91993635c8eeaf9f49e55906907277b8a68b017e'
review_loop_iteration: 2
followup_review_recommended: false
context: []
warnings: ['oversized']
deferred:
  - summary: >-
      Two related TOCTOU (time-of-check-to-time-of-use) races exist in VaultWriter,
      both requiring an external actor to change filesystem state in a narrow window
      between a check and a later use: (1) between the collision-detection existence
      check and AtomicWriter's own rename(2) call, a different process could create a
      file at the exact resolved target path, which rename would then silently
      overwrite; (2) between vaultPath's own validation and the later (intermediate-
      directory-creating) meetingsSubdir auto-creation call, vaultPath could in
      principle be deleted, causing that call to silently recreate it with
      default rather than inherited permissions -- violating the "never auto-create
      vaultPath" invariant.
    evidence: |-
      Both real, but not fixable within this story's scope without a disproportionate
      cost. (1) AtomicWriter's own doc comment already states "callers are responsible
      for serializing writes to a given path" -- it does not offer collision-safe
      (exclusive-create) semantics, and adding them would mean either modifying
      AtomicWriter (an already-shipped, already-tested Story 1.2 primitive, out of
      scope here) or building new cross-process serialization machinery no
      architecture document currently specifies. (2) Review iteration 1 tried closing
      this one by disabling intermediate-directory creation for meetingsSubdir
      entirely, but that broke a real, documented configuration shape -- Decision
      2.5's own rationale text gives "inbox/Meetings/" as an example meetings_subdir
      value, a nested path that needs multiple intermediate directories created.
      Iteration 2 reverted that fix in favor of accepting the underlying race, since
      supporting the documented nested-subdir case is more valuable than closing an
      even-narrower slice of an already-narrow window. Both races require two
      independent, near-simultaneous events (this call, plus some other actor
      deleting/creating the exact path in question at the exact right microsecond) --
      the same "low-probability, manually recoverable" class of trade-off Decision 2.4
      already explicitly accepts for cross-Mac filename collisions. What would settle
      it: whether a future story gives AtomicWriter (or a sibling primitive) an
      exclusive-create write mode (e.g. macOS's renamex_np(RENAME_EXCL) where
      available), which would close race (1); race (2) would need VaultWriter to walk
      and create meetingsSubdir's path components one at a time rather than passing
      withIntermediateDirectories: true, verifying vaultPath itself is never the
      directory actually created.
    location: >-
      Sources/Persist/VaultWriter.swift (collisionFreeTarget, resolveMeetingsSubdir, write)
    severity: low (unverified) -- both require a narrow concurrent race; race (1) degrades to a silently and permanently overwritten colliding note (real data loss of that note's prior content, though not corruption of the write-in-progress itself), race (2) to a mis-permissioned auto-created vaultPath -- neither crashes or corrupts the write actually being performed
---

<intent-contract>

## Intent

**Problem:** `Persist/VaultWriter.swift` doesn't exist yet. Nothing in the codebase can take rendered markdown (Story 2.1) and a resolved filename (Story 2.2) and actually publish it into the user's Obsidian vault safely — validating the vault path, auto-creating auricle's own subdirectory, handling same-day filename collisions, and never risking a partial write.

**Approach:** Add `Persist/VaultWriter.swift`, composing `Core/AtomicWriter` (never bypassing it) with vault-path/subdirectory validation and same-Mac collision handling via `FilenameResolver`'s ordinal parameter, covering the standard fresh-publish path this story is scoped to.

## Boundaries & Constraints

**Always:**
- `VaultWriter.write(_:meeting:vaultPath:meetingsSubdir:)` composes `Core/AtomicWriter.write(_:to:)` for the actual write — never a direct `Data.write`/`FileManager` call. (The repo's existing `.swiftlint.yml` `atomic_writer_bypass` custom rule already forbids `.write(to:`/`FileManager...createFile(` anywhere outside `AtomicWriter.swift` itself and two named test files — this rule already covers `VaultWriter.swift` with zero new configuration; do not add a second, redundant rule.)
- `vaultPath` and `meetingsSubdir` arrive **pre-resolved by the caller** as a `URL` and a `String` respectively — this function never reads a config file or a `Config` type (none exists in this codebase yet; the nearest sibling pattern is `MeetingForFrontmatter`/`MeetingForFilename` accepting only pre-resolved values from Story 2.1/2.2).
- Validate `vaultPath` on every call: it must already exist as a directory and be writable. **Never auto-create it** — per Decision 2.5, accidentally creating someone's vault is a worse failure than refusing to publish.
- Resolve `meetingsSubdir` on every call: if `vaultPath/meetingsSubdir` doesn't exist, auto-create it (auricle owns this one subdirectory, so auto-creation here is safe) with permissions inherited from `vaultPath`; if it exists as a directory, use it; if it exists as a non-directory file, or as a non-writable directory, fail fast with a typed error before attempting any write.
- Resolve the filename via `FilenameResolver.resolve(meeting:)` (Story 2.2), then check whether `vaultPath/meetingsSubdir/<filename>` already exists. If it does, retry with `FilenameResolver.resolve(meeting:, ordinal: 2)`, then `3`, incrementing until an unused path is found (Decision 2.4's deterministic, never-random ordinal counter) — then write there via `AtomicWriter`. This retry loop has a **fixed upper bound** (matching every other failure mode in this function, which fails fast with a typed error rather than looping indefinitely) — see Design Notes for the exact cap and the new error case it throws once exhausted.
- `meetingsSubdir` may itself be a nested relative path (Decision 2.5's own rationale text gives `inbox/Meetings/` as an example config value, alongside a flat `auricle/`) — auto-creation must support this, creating every missing path component under `meetingsSubdir` normally. (Review iteration 1 tried disabling intermediate-directory creation entirely to close a separate, narrower race — see Spec Change Log for why that was itself a regression, corrected in iteration 2.)
- Return the absolute `URL` actually written (which may carry an ordinal suffix if a collision was resolved).
- Meet NFR-P8: a 50KB markdown payload writes in ≤500ms on reference hardware (this is `AtomicWriter`'s own budget to meet; verify it holds through `VaultWriter`'s thin composition layer, don't re-derive a new performance primitive).
- `write`'s own doc comment states, not just implies, that it inherits `AtomicWriter`'s "not safe to call concurrently for the same path" constraint (`AtomicWriter.write`'s own doc comment already says this — `VaultWriter` adds no serialization of its own on top, so a caller reading only `VaultWriter`'s public API needs the same warning, not just `AtomicWriter`'s).
- A test proves `write` propagates (rather than swallows or translates) an `AtomicWriter.WriteError` from the underlying write, using a deterministic trigger — see the new I/O matrix row below.

**Never:**
- Never construct a re-publish (`--rerun-<date>`) filename or suffix — that's `PersistStage`'s concern (Story 2.4, not yet built), a different axis (double-hyphen + date) from this story's same-day-collision suffix (single-hyphen + ordinal), per Decision 2.3/2.4's explicit discriminator. This story's `write` always runs the fresh-publish collision path; a future re-publish caller is out of scope here and will be addressed when Story 2.4 is planned, not anticipated speculatively now.
- Never open an existing vault file for write, under any code path — `AtomicWriter` itself only ever creates a new temp file and renames it into place; `VaultWriter` must not add any write path that doesn't go through it.
- Never introduce a `Config`/settings-reading dependency — `vaultPath`/`meetingsSubdir` are parameters, not something this function looks up itself.
- Never introduce a snapshot-testing library — hand-written expected-value assertions via Swift Testing (`import Testing`, `@Test`, `#expect`), matching this repo's house style (Stories 2.1/2.2's own test files, and `Tests/CoreTests/AtomicWriterTests.swift`'s temp-directory-per-test / `defer`-cleanup pattern for filesystem tests).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy path, subdir already exists | `vaultPath` exists+writable, `meetingsSubdir` exists as a writable directory, no filename collision | Markdown written atomically to `vaultPath/meetingsSubdir/<resolved-filename>`; returns that URL | No error expected |
| `vaultPath` missing | `vaultPath` doesn't exist on disk | Fails fast, resolved path and reason in the error; vault is never auto-created | Typed error naming the missing path |
| `vaultPath` exists but not writable | e.g. read-only permissions | Fails fast | Typed error naming the path and reason |
| `meetingsSubdir` missing | `vaultPath` valid, subdir doesn't exist yet | Auto-created (permissions inherited from `vaultPath`), then the write proceeds normally | No error expected |
| `meetingsSubdir` is a nested relative path, none of it exists yet | e.g. `meetingsSubdir: "inbox/Meetings"` (Decision 2.5's own documented example shape) | Every missing intermediate component is auto-created, then the write proceeds normally | No error expected |
| `meetingsSubdir` creation genuinely fails | A path component of `meetingsSubdir` (not `meetingsSubdir` itself) already exists as a regular file, blocking the nested directory from being created underneath it | Fails fast with `.meetingsSubdirCreationFailed`, naming the full nested path | Typed error naming the path and the underlying `FileManager` error |
| `meetingsSubdir` exists as a file, not a directory | e.g. a stray file at that path | Fails fast before attempting any write | Typed error naming the path |
| `meetingsSubdir` exists as a non-writable directory | e.g. read-only permissions | Fails fast before attempting any write | Typed error naming the path |
| Same-Mac filename collision | A file already exists at the freshly-resolved (no-ordinal) path | Retries via `FilenameResolver.resolve(meeting:, ordinal: 2)`; if that also collides, tries `3`, etc., until free; writes there; the original colliding file is untouched | No error expected |
| Two successive same-Mac collisions | Files already exist at both the no-ordinal path and the `-2` path | Retries past `-2` to `-3`; writes there — proves the counter genuinely advances on each successive collision, not just once | No error expected |
| `vaultPath` exists as a regular file, not a directory | e.g. a stray file at the configured `vaultPath` location | Fails fast with the same `.vaultPathMissing` error as a missing path — "exists as a directory" is the actual requirement, not merely "exists" | Typed error naming the path |
| Collision retries exhausted | Every ordinal up to the fixed cap already collides (pre-seed that many colliding files, or a small test-only cap) | Fails fast with a typed error rather than looping indefinitely | Typed error naming the path and the cap reached |
| Underlying `AtomicWriter` write itself fails, after all of `VaultWriter`'s own checks pass | A directory (not a file) pre-exists at `AtomicWriter.temporaryURL(for:)` for the resolved target — a deterministic trigger, not a race: `AtomicWriter`'s own `createFile` call fails with `EISDIR` before any rename is attempted | `write` throws `AtomicWriter.WriteError.createTemporaryFileFailed`, propagated unchanged; no file exists at the target afterward | Propagated `AtomicWriter.WriteError`, not swallowed or translated |
| Simulated process-kill before rename | A leftover `AtomicWriter`-style temp file already sits at the resolved target's temp path (from a hypothetical prior interrupted run) | The next `VaultWriter.write` call succeeds normally, producing a complete target file and no leftover temp file — the same recovery guarantee `AtomicWriter`'s own test suite already covers, verified again at `VaultWriter`'s call site | No error expected |
| 50KB markdown payload | Realistic large note content | Completes in ≤500ms (NFR-P8) | No error expected |

</intent-contract>

## Code Map

- `Sources/Persist/VaultWriter.swift` -- new. `public enum VaultWriter { public static func write(_ markdown: String, meeting: MeetingForFilename, vaultPath: URL, meetingsSubdir: String) throws -> URL }`.
- `Sources/Persist/FilenameResolver.swift` -- existing (Story 2.2). `FilenameResolver.resolve(meeting:ordinal:) -> String`; `VaultWriter` calls this directly for both the initial resolve and each ordinal retry.
- `Sources/Persist/MeetingForFilename.swift` -- existing (Story 2.2). The exact input type `VaultWriter.write` forwards to `FilenameResolver`.
- `Sources/Core/AtomicWriter.swift` -- existing (Story 1.2). `AtomicWriter.write(_ data: Data, to path: URL) throws`, `AtomicWriter.temporaryURL(for:) -> URL`. `VaultWriter` composes this for the actual write; never duplicates its temp/fsync/rename sequence.
- `.swiftlint.yml:97-122` -- the existing `atomic_writer_bypass` custom rule. Its regex (`\.write\(to:|FileManager\(\)\.createFile\(|FileManager\.(default\.)?createFile\(`) and exclusion list already cover any file outside `AtomicWriter.swift` and two named `CoreTests`/`OrchestratorTests` files — `Sources/Persist/VaultWriter.swift` needs no new entry here and this story adds no new custom rule.
- `Tests/CoreTests/AtomicWriterTests.swift` -- existing. `killedBeforeRenameLeavesTempFileAndNoPartialTarget()` (lines 24-45) is the house pattern for simulating a process-kill: write directly to `AtomicWriter.temporaryURL(for:)`, assert the leftover temp file and no target, then call the real write and assert recovery. `VaultWriter`'s own process-kill test follows this same shape at the vault-resolved path.
- `_bmad-output/planning-artifacts/architecture.md:986-1010` -- Decision 2.5 (vault path defaulting, the two-knob `vault_path`/`meetings_subdir` split and its exact validation rules) — the normative source for this story's path-resolution behavior.
- `_bmad-output/planning-artifacts/architecture.md:919-985` -- Decision 2.4 (collision handling: same-day ordinal counter vs. re-publish's separate double-hyphen suffix) — the normative source for this story's collision-handling behavior.
- `_bmad-output/planning-artifacts/epics.md:1220-1258` -- Story 2.3's full acceptance criteria (already distilled into this spec's intent-contract).
- `Package.swift` -- `Persist`/`PersistTests` targets already exist with the right dependencies (`Persist`: `Core`, `State`, `Telemetry`, plus `Yams` since Story 2.1; `PersistTests`: `Persist`, `TestSupport`); no target wiring needed for this story.

## Tasks & Acceptance

**Execution:**
- `Sources/Persist/VaultWriter.swift` -- implement `write(_:meeting:vaultPath:meetingsSubdir:)`: validate `vaultPath`, resolve/validate/auto-create `meetingsSubdir`, resolve the filename (retrying with an incrementing ordinal on collision), then delegate the actual write to `AtomicWriter` -- the behavior under test.
- `Tests/PersistTests/VaultWriterTests.swift` -- new. One `@Test` per I/O-matrix row above — count rows directly rather than trust a restated number here. Use a fresh temp directory per test, registering its `defer { removeItem(...) }` cleanup immediately after creating the directory (matching `AtomicWriterTests.swift`'s `makeTestDirectory()` pattern) — not after any later setup step that could itself throw and skip cleanup — so tests never touch a real vault path and never leak a temp directory on a failing setup step.

**Acceptance Criteria:**
- Given a valid `vaultPath` and `meetingsSubdir`, when `write(_:meeting:vaultPath:meetingsSubdir:)` is called, then the markdown lands at `vaultPath/meetingsSubdir/<filename>` atomically (via `AtomicWriter`) and the returned URL matches that path exactly.
- Given `vaultPath` missing or not writable, when `write` is called, then it throws before any write attempt, and the thrown error's associated value names the resolved path.
- Given `meetingsSubdir` missing, when `write` is called, then it is auto-created (inheriting `vaultPath`'s permissions) and the write proceeds; given `meetingsSubdir` exists as a file or as a non-writable directory, when `write` is called, then it throws before any write attempt.
- Given a file already exists at the freshly-resolved (no-ordinal) target path, when `write` is called, then it retries with `FilenameResolver`'s ordinal parameter (2, then 3, ...) until it finds an unused path, writes there, and leaves the original colliding file's contents untouched — proven by a test where collisions exist at *two* successive ordinals, not just one.
- Given `vaultPath` exists as a regular file rather than a directory, when `write` is called, then it throws `.vaultPathMissing`, the same as a missing path.
- Given every ordinal up to the fixed cap already collides, when `write` is called, then it throws a typed error rather than looping indefinitely.
- Given a nested `meetingsSubdir` value (e.g. `"inbox/Meetings"`) where no component exists yet, when `write` is called, then every missing intermediate component is created and the write proceeds normally.
- Given a path component of `meetingsSubdir` already exists as a regular file (blocking the nested directory from being created underneath it), when `write` is called, then it throws `.meetingsSubdirCreationFailed` before any write attempt.
- Given a 50KB markdown string, when `write` is called, then it completes in ≤500ms.

## Spec Change Log

### 2026-09-16 — Review pass 1 (bad_spec)

**Triggering findings:** Blind Hunter and Edge Case Hunter both independently found that `collisionFreeTarget`'s `while true` retry loop has no upper bound — a `FilenameResolver` defect or a genuine data-corruption scenario producing endless collisions would hang `write` indefinitely instead of failing fast, inconsistent with every other failure mode in this function (all of which throw a typed `WriteError`). Edge Case Hunter separately found that auto-creating `meetingsSubdir` used `withIntermediateDirectories: true`, which — in the freak case that `vaultPath` disappeared in the narrow window between its own validation and this call — would silently recreate `vaultPath` itself with default (non-inherited) permissions, violating the explicitly-stated "never auto-create `vaultPath`" invariant. The Verification Gap Reviewer separately found two real, demonstrated test-coverage gaps with concrete regression scenarios: the collision-retry test only ever seeds one colliding file, so a counter that stops advancing after exactly one retry would still pass; and no test constructs a `vaultPath` that exists as a regular file (as opposed to missing entirely), so the `isDirectory` half of the missing-path guard is unexercised. Blind Hunter additionally found a stale "8 tests" count (the matrix has more rows and the shipped suite has 9 tests) and a Code Map omission (`Persist` also depends on `Yams` since Story 2.1, not just `Core`/`State`/`Telemetry`).

**What was amended:** Boundaries gained two new bullets (the fixed collision-retry cap; `meetingsSubdir` auto-creation must create only that one directory, not any missing ancestors). The I/O matrix gained 4 new rows (two successive collisions, `vaultPath`-as-a-file, collision-retries-exhausted). Design Notes' pseudocode was rewritten to match: a new `WriteError.collisionRetriesExhausted` case, a `maxCollisionOrdinal` constant, `withIntermediateDirectories: false` for the subdir creation, and a corrected doc-comment guidance note listing both error domains a caller can catch. The stale test count was replaced with an instruction to count matrix rows directly. The Code Map's dependency list was corrected. A separate finding (the TOCTOU race between this function's own existence check and `AtomicWriter`'s unconditional `rename(2)`) was *not* amended into a code fix — see the frontmatter `deferred` entry for why fixing it properly is out of this story's scope.

**Known-bad state avoided:** a pathological or corrupted collision scenario would have hung `VaultWriter.write` forever with no error and no timeout; a vault path that vanished in a narrow race window during subdir creation could have had itself silently recreated with the wrong permissions, defeating the one invariant Decision 2.5 treats as load-bearing ("creating someone's vault by accident is a worse failure than refusing to publish").

**KEEP instructions (must survive re-derivation):** everything else about the original implementation was correct and independently verified by the orchestrating agent (42/42 `PersistTests`, 163/163 full suite, 0 swiftlint/swiftformat violations, all 6 custom lint rule fixtures still firing) — the overall signature and composition-over-`AtomicWriter` design, the `WriteError` case shape (aside from the one addition above), the `vaultPath`/`meetingsSubdir` validation logic (aside from the `withIntermediateDirectories` fix), the collision-detection-via-`FilenameResolver` approach, the `.swiftlint.yml` exclusion-list addition for `VaultWriterTests.swift` (confirmed necessary and correctly scoped — the custom rule fires correctly against the fixture file and against the test file without the exclusion), and the file layout. Re-derive by keeping all of that and adding: the collision-retry cap + new error case, the `withIntermediateDirectories: false` fix, and the new/updated tests.

### 2026-09-16 — Review pass 2 (bad_spec)

**Triggering findings:** the Verification Gap Reviewer found — and empirically demonstrated, disproving iteration 1's own rejection of a near-identical finding — that `.meetingsSubdirCreationFailed` is reliably testable: a `meetingsSubdir` with a missing intermediate component (e.g. `"NoSuchParent/Meetings"`) makes `createDirectory(withIntermediateDirectories: false)` fail deterministically with `ENOENT`, no race required. That demonstration exposed a bigger problem with iteration 1's own fix: Blind Hunter and the Intent Alignment Auditor both separately flagged that Decision 2.5's own rationale text names `"inbox/Meetings/"` as an example `meetings_subdir` config value — a nested path — and iteration 1's `withIntermediateDirectories: false` change (intended to stop `vaultPath` from being silently recreated in a narrow race) also makes every genuinely nested `meetingsSubdir` value fail to auto-create at all, a real regression against a documented configuration shape, not just an untested corner. Separately: Blind Hunter found the collision-retry cap test hardcodes `1000`, duplicating the (then-`private`) production constant with no compiler-enforced link; a test's `defer` cleanup registered after a step that could itself throw, risking a leaked temp directory on that failure path; a stale test count in this very Spec Change Log's own iteration-1 entry ("9" vs. the shipped suite's actual 12); and an under-documented `collisionRetriesExhausted.path` semantic (it's the *last* colliding candidate, not something else).

**What was amended:** reverted iteration 1's `withIntermediateDirectories: false` back to `true`, restoring nested-`meetingsSubdir` support, and accepted the narrower residual `vaultPath`-recreation race by folding it into the existing `deferred` entry (broadened to cover both related TOCTOU races together, rather than adding a second one) — since a full fix would mean walking `meetingsSubdir`'s path components one at a time, a proportionally larger change for an already-narrow race. Added two new I/O-matrix rows and AC bullets: nested `meetingsSubdir` auto-creates correctly; a file blocking a nested path component throws `.meetingsSubdirCreationFailed` (using the reviewer's verified-deterministic trigger, restated for the reverted `true` behavior — a *file*, not a *missing parent*, is what reliably blocks creation once intermediate creation is re-enabled). `maxCollisionOrdinal` changed from `private` to internal (default access), so its dedicated test can reference the real constant instead of a hardcoded duplicate. Design Notes' pseudocode and the `collisionRetriesExhausted` case doc comment were corrected to match. The Tasks section's test-cleanup guidance now specifies registering `defer` immediately after directory creation, not after any later, possibly-throwing setup step. The stale test count was corrected.

**Known-bad state avoided:** a user who configured `meetings_subdir` as a nested path — the exact shape Decision 2.5's own documentation offers as an example — would have had every publish attempt fail with `.meetingsSubdirCreationFailed` on first use, a real usability regression iteration 1 introduced while trying to close an unrelated, much narrower race.

**KEEP instructions (must survive re-derivation):** everything from iteration 1 remains correct except the `withIntermediateDirectories` value and the `maxCollisionOrdinal` constant's access level: the bounded collision-retry loop and its new error case, the `vaultPath`-as-a-file check, the overall signature and composition-over-`AtomicWriter` design, the rest of the `WriteError` case shape, the collision-detection-via-`FilenameResolver` approach, and the `.swiftlint.yml` exclusion. Re-derive by keeping all of that, restoring `withIntermediateDirectories: true`, widening `maxCollisionOrdinal`'s access, and adding the two new tests plus the cleanup-ordering fix to every test in the file.

## Review Triage Log

### 2026-09-16 — Review pass 1
- verdicts: 20 findings — high 0, medium 0, low 6, false 9, maybe-false 0 (4 findings route to `bad_spec` sharing two root causes, 1 routes to `defer` — not counted as a severity verdict; this line's totals corrected in pass 3 after the original didn't match its own itemized list below)
- findings:
  - `[bad_spec]` (Blind Hunter) `collisionFreeTarget`'s `while true` loop has no upper bound — a defect or pathological input hangs `write` forever instead of failing fast, inconsistent with this function's own pattern elsewhere. Amended: fixed cap + new `WriteError` case (see Spec Change Log).
  - `[bad_spec]` (Edge Case Hunter, same root cause) Unbounded loop; `ordinal + 1` could in principle trap on `Int` overflow at `Int.max` — grouped with the above; the practical fix (a low, sane cap) makes the overflow scenario moot too.
  - `[bad_spec]` (Edge Case Hunter) `meetingsSubdir` auto-creation uses `withIntermediateDirectories: true`, which could silently recreate a `vaultPath` that disappeared in a narrow race window, with non-inherited permissions — violating the stated "never auto-create `vaultPath`" invariant. Amended: `withIntermediateDirectories: false` (see Spec Change Log).
  - `[bad_spec]` (Blind Hunter, same root cause) Confirmed the same finding independently — a `vaultPath`-recreation risk via the subdir-creation call's `withIntermediateDirectories: true`; grouped with the above.
  - `[low]` `[patch-via-rederivation]` (Verification Gap Reviewer) The collision-retry test only seeds one colliding file, so a counter that stops advancing after the first retry would still pass — verified: a hypothetical hardcoded `ordinal = 2` would produce identical output on the existing test. Added a new test seeding two successive collisions, asserting the result lands at `-3`.
  - `[low]` `[patch-via-rederivation]` (Verification Gap Reviewer) No test constructs a `vaultPath` that exists as a regular file (vs. missing entirely), so the `isDirectory` half of the missing-path guard is unexercised — verified: dropping that half of the compound guard leaves both existing `vaultPath` tests passing unchanged. Added a new test.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter and Edge Case Hunter, same finding) The Tasks section's stated test count ("8 tests") doesn't match the matrix's row count or the shipped suite (9) — replaced with an instruction to count rows directly.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) Code Map's `Persist` dependency list omitted `Yams` (added in Story 2.1) — corrected.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) `write`'s doc comment documents its return value but not what it throws — added a note listing both error domains (`VaultWriter.WriteError` and propagated `AtomicWriter.WriteError`).
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) Design Notes' pseudocode had drifted from the shipped implementation's actual `ordinal: Int?` shape — corrected to match, and to include the new cap/error case.
  - `[defer]` (Blind Hunter and Edge Case Hunter, same finding) A TOCTOU race exists between `collisionFreeTarget`'s existence check and `AtomicWriter`'s own unconditional `rename(2)` — a concurrent writer could silently overwrite a colliding note. Real, but fixing it properly requires modifying `AtomicWriter` (an already-shipped, already-tested Story 1.2 primitive) or new cross-process serialization machinery neither of which this story's scope covers; added to frontmatter `deferred`.
  - `[false]` `[reject]` (Blind Hunter) `WriteError.meetingsSubdirCreationFailed` has zero test coverage — real gap, but reliably forcing `FileManager.createDirectory` to fail while `vaultPath` itself passes both the existence and writability checks requires a genuinely fragile, OS-level race that isn't practical to construct portably in a unit test; accepted as untested, matching the precedent set for similarly-hard-to-force defensive error paths in Stories 2.1/2.2 (e.g. `FrontmatterRenderer`'s unreachable `fatalError` catch, `FilenameResolver`'s unreachable source-4 fallback).
  - `[false]` `[reject]` (Blind Hunter) `inheritedPermissions`'s silent `nil`-on-failure fallback to default (umask-derived) permissions isn't documented as a fallback path — real but low-value: `try?` swallowing a permissions-read failure is a reasonable defensive default, and forcing that specific failure reliably in a test has the same fragility problem as the finding above; not pursued further.
  - `[false]` `[reject]` (Edge Case Hunter) `meetingsSubdir` isn't validated against `..` traversal or an empty/absolute value — no adversarial threat model applies: it's a value the user configures on their own single-user machine, where they already have unrestricted filesystem access; matches the "trust the caller/config" boundary this epic applies throughout (including to `vaultPath` itself, which is equally unvalidated for traversal-style values).
  - `[false]` `[reject]` (Edge Case Hunter) TOCTOU between `collisionFreeTarget`'s check and `AtomicWriter`'s rename — same finding as the Blind Hunter one above, routed to `defer` there; not double-counted as a separate rejection.
  - `[false]` `[reject]` (Intent Alignment Auditor) `VaultWriter.write`'s actual signature (`meeting:vaultPath:meetingsSubdir:`) diverges from the AC's illustrative `write(_:to:)` snippet — deliberate and already documented in this spec's own Design Notes: the illustrative signature can't support the AC's own collision-handling requirement, which needs the full `MeetingForFilename` to re-derive an ordinal-suffixed name. Independently corroborated by `FilenameResolver.swift`'s own doc comment (committed under Story 2.2, before this story began), which already names this exact division of responsibility.
  - `[false]` `[reject]` (Intent Alignment Auditor) `vaultPath` validation happens at call-time in this diff, not at launch-time via `auricle doctor`/CLI as Decision 2.5 frames it — deliberate and already documented: this story's own call-time validation is defense-in-depth on top of a launch-time check that belongs to Epic 9 (not yet built), not a replacement for it.
  - `[false]` `[reject]` (Intent Alignment Auditor) No test in `VaultWriterTests.swift` specifically asserts VaultWriter "never opens an existing file for write," as the AC's own phrasing calls for — deliberate and already documented in this spec's Code Map: that guarantee is carried by the pre-existing `atomic_writer_bypass` swiftlint rule plus `AtomicWriter`'s own test suite (a different, already-shipped story), since `VaultWriter` never does its own file I/O beyond calling `AtomicWriter.write`; a redundant proxy test in this file would test `AtomicWriter`'s internals a second time through an indirect path.
  - `[false]` `[reject]` (Intent Alignment Auditor) The re-publish discriminator ("AND this is NOT a re-publish path") is satisfied only vacuously today, since no re-publish caller exists — deliberate and already documented in this spec's Boundaries "Never" section as explicitly out of scope, Story 2.4's concern.
  - `[false]` `[reject]` (Intent Alignment Auditor) The genuine tension between the AC's illustrative signature and its collision-handling requirement was resolved via design judgment rather than reported as "blocked" — reaffirms the precedent from Stories 2.1/2.2: this workflow's own `bad_spec` self-correction mechanism is the sanctioned way to resolve a spec-level ambiguity discovered during implementation or review, distinct from "blocked," which is reserved for gaps no amount of in-loop correction can resolve (an intent_gap, not what happened here).

### 2026-09-16 — Review pass 2
- verdicts: 18 findings — high 0, medium 0, low 4, false 10, maybe-false 0 (4 findings route to `bad_spec` sharing one root cause — not counted as a severity verdict; this line's totals corrected in pass 3 after the original didn't match its own itemized list below)
- findings:
  - `[bad_spec]` (Verification Gap Reviewer) `.meetingsSubdirCreationFailed` is in fact reliably testable — disproving iteration 1's own rejection — via a `meetingsSubdir` with a missing intermediate component under `withIntermediateDirectories: false`. Verified directly (standalone reproduction: `createDirectory` fails deterministically with `NSCocoaErrorDomain Code=4`/`ENOENT` for a missing intermediate, no race). This demonstration is what surfaced the deeper problem below.
  - `[bad_spec]` (Blind Hunter) Decision 2.5's own rationale text names `"inbox/Meetings/"` as an example `meetings_subdir` value — a nested path — which iteration 1's `withIntermediateDirectories: false` fix makes fail to auto-create at all. Verified against the primary source (`architecture.md`, Decision 2.5's "Why split into two knobs" paragraph). Root cause: iteration 1 over-corrected a narrow race by breaking a documented, common configuration shape. Amended: reverted to `withIntermediateDirectories: true` (see Spec Change Log).
  - `[bad_spec]` (Intent Alignment Auditor, same root cause) Independently surfaced the same "inbox/Meetings/" documented example as evidence the nested-subdir case is real and must be supported; grouped with the above.
  - `[bad_spec]` (this agent, same root cause, found while designing the fix) Confirmed via direct execution that a *file* blocking a nested path component (not a missing parent) is the deterministic trigger for `.meetingsSubdirCreationFailed` once `withIntermediateDirectories: true` is restored — the Verification Gap Reviewer's original trigger (missing parent) stops working once intermediate creation is re-enabled, so the test needed a different, still-deterministic construction. Added as a new I/O-matrix row and test.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) `throwsCollisionRetriesExhaustedWhenEveryOrdinalUpToTheCapCollides` hardcodes `1000`, duplicating the (then-`private`) production constant with no compiler-enforced link — changed `maxCollisionOrdinal` from `private` to internal access so the test references the real value.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) `throwsMeetingsSubdirNotWritableWhenExistsAsAReadOnlyDirectory` registers its cleanup `defer` after a step that could itself throw, unlike every other test in the file — verified by inspection. Fixed: cleanup guidance now specifies registering `defer` immediately after directory creation across all tests.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) This spec's own Spec Change Log (iteration 1's entry) states the shipped suite has "9 tests," but it actually has 12 — corrected.
  - `[low]` `[patch-via-rederivation]` (Blind Hunter) `WriteError.collisionRetriesExhausted`'s `path` field (the *last* colliding candidate) isn't documented clearly enough for a future caller writing log output — added a doc comment.
  - `[false]` `[reject]` (Blind Hunter) `meetingsSubdir` containing a path separator (nested) might not be a supported configuration value — resolved by the bad_spec fix above: it is supported, per Decision 2.5's own example, and is now both implemented and tested.
  - `[false]` `[reject]` (Blind Hunter) `meetingsSubdir = ""` silently resolves to `vaultPath` itself with no error — real behavior, but `""` was never a documented example value (Decision 2.5's default is `"Meetings"`); matches the established "trust the caller/config" boundary applied throughout this epic, the same reasoning already used to reject `..`-traversal validation in pass 1.
  - `[false]` `[reject]` (Blind Hunter) The pass-1 Spec Change Log's "KEEP instructions" cite "42/42"/"163/163" test counts that no longer match the current worktree state — not a defect: that entry is an append-only historical record of what was true *as of that pass*, the same convention used throughout this spec and its Story 2.1/2.2 predecessors, not a claim about current state.
  - `[false]` `[reject]` (Blind Hunter) `VaultWriter.WriteError` has no `LocalizedError`/`CustomStringConvertible` conformance, so a caller-facing message would show a raw enum dump — matches the established convention `AtomicWriter.WriteError` (the type this one explicitly follows) already uses; presentation-layer formatting is deliberately left to whoever displays the error (a CLI verb, once one exists), not this type's job.
  - `[false]` `[reject]` (Blind Hunter) No test exercises "`write` propagates `AtomicWriter.WriteError`" specifically — a real gap, but reliably forcing `AtomicWriter`'s own internal write to fail *after* all of `VaultWriter`'s own checks pass requires a similarly fragile, hard-to-construct-portably scenario as the (now-resolved) `.meetingsSubdirCreationFailed` gap was thought to be; unlike that one, no deterministic trigger was found for this pass, so it's accepted as untested rather than pursued further.
  - `[false]` `[reject]` (Blind Hunter) `chmod 0o500`-based writability tests could behave differently under a root-executed test run (e.g. some CI/Docker configurations bypass permission bits) — a real portability caveat for some hypothetical environment, but no evidence this repo's actual CI runs as root; not pursued without a concrete trigger in the environment that matters.
  - `[false]` `[reject]` (Edge Case Hunter) `meetingsSubdir` empty-string and `..`-traversal validation — reaffirms pass 1's verdict: no adversarial threat model applies to a single-user-configured value.
  - `[false]` `[reject]` (Edge Case Hunter) TOCTOU between the collision-existence check and `AtomicWriter`'s rename — same finding already routed to `defer` in pass 1 (now broadened to cover the related `meetingsSubdir` race too); not double-counted.
  - `[false]` `[reject]` (Intent Alignment Auditor) `VaultWriter`'s actual signature taking `meeting: MeetingForFilename` may make Story 2.4's own described flow (resolve filename once in `PersistStage`, hand `VaultWriter` a string) partially redundant once Story 2.4 exists — a genuinely well-reasoned point, but explicitly out of this story's scope per this spec's own Boundaries "Never" section: that's Story 2.4's own spec to resolve, once it exists, not speculative design here. Reaffirms pass 1's identical response to the same category of concern.
  - `[false]` `[reject]` (Intent Alignment Auditor) The collision-retry cap (and its dedicated error case/test) has no antecedent in `epics.md`/`architecture.md` — it was invented entirely within this review loop — accurate, but this is exactly what the `bad_spec` self-correction mechanism exists for: closing a real robustness gap the planning docs simply never addressed, not a deviation from something they did specify.

### 2026-09-16 — Review pass 3
- verdicts: 17 findings — high 0, medium 0, low 4, false 13, maybe-false 0 (all 4 `low` entries route to `patch`, two of them sharing one root cause)
- findings:
  - `[low]` `[patch]` (Blind Hunter) Pass 2's rejection of "no deterministic trigger for testing `AtomicWriter.WriteError` propagation" was itself wrong — verified directly (standalone probe): pre-creating a *directory* (not a file) at `AtomicWriter.temporaryURL(for:)` before calling `write` makes the underlying `createFile` fail deterministically with `EISDIR`, no race required, and `VaultWriter` correctly propagates `AtomicWriter.WriteError.createTemporaryFileFailed` unchanged. Added as a new I/O-matrix row and (via re-engaging the implementation agent, not a full bad_spec revert — the code itself is already correct, only test coverage was missing) a new test.
  - `[low]` `[patch]` (Verification Gap Reviewer, same root cause) Independently found and demonstrated the identical gap with the identical trigger; grouped with the above, not double-counted.
  - `[low]` `[patch]` (Blind Hunter) `write`'s doc comment doesn't state that it inherits `AtomicWriter`'s "not safe to call concurrently for the same path" constraint — added to the Boundaries section and, via the same implementation-agent re-engagement, the function's own doc comment.
  - `[false]` `[reject]` (Blind Hunter) `epics.md`'s AC calls for the never-opens-an-existing-file guarantee to be verified by "a unit test that asserts the open mode," which `VaultWriterTests.swift` doesn't have — reaffirms passes 1-2's verdict, now with a sharper citation: `VaultWriter.swift` has exactly one file-writing call site (`AtomicWriter.write(...)`, confirmed by direct inspection) and no alternate path of its own: a VaultWriter-level "open mode" test would only re-test `AtomicWriter`'s own internals (already covered, a different story's test suite) through an indirect proxy, adding no coverage a direct `AtomicWriter` test doesn't already provide.
  - `[false]` `[reject]` (Blind Hunter) Design Notes pseudocode still read `ordinal = 2` as an eager assignment, not matching the shipped `var ordinal: Int?` control flow, despite two prior passes claiming to have corrected it — verified true (a real, persistent documentation staleness this pass finally closes) — corrected directly in this pass; not routed as a separate `patch`/`bad_spec` entry since it's a pure documentation fix with no behavioral implication, matching the "fix is to edit this build's spec" exclusion applied consistently since pass 1.
  - `[false]` `[reject]` (Blind Hunter) The `.swiftlint.yml` exclusion comment for `VaultWriterTests.swift` names only 3 of the ≥5 raw-filesystem-state setups the test file performs — accurate but low-value: the comment explains *why* the exclusion exists, not an exhaustive enumeration of every test; not pursued further.
  - `[false]` `[reject]` (Blind Hunter) Pass 2's Spec Change Log states the shipped suite has "12" tests; the actual final count (after this pass's own additions) is higher — same append-only historical-snapshot convention already established and accepted for the "42/42 tests" finding in pass 2: each Spec Change Log entry is a record of what was true *as of that pass*, not a live claim about current state.
  - `[false]` `[reject]` (Blind Hunter) `makeTestDirectory()` in `VaultWriterTests.swift` duplicates the identical helper in `AtomicWriterTests.swift` instead of using the shared `TestSupport` target — a reasonable dedup opportunity, but it would mean modifying `AtomicWriterTests.swift`, an already-shipped Story 1.2 test file, which is out of this story's scope to touch.
  - `[low]` `[patch]` (Blind Hunter) Review pass 1's and pass 2's own "verdicts:" summary lines didn't match their itemized lists below them (wrong total finding count, and `low`/`false` sub-counts both wrong in both passes) — verified by direct recount of the tagged bullets in each section. Corrected both summary lines in place (an append-only log's own bookkeeping-accuracy fix, not a change to any finding's substance).
  - `[false]` `[reject]` (Edge Case Hunter) `vaultPath` deleted between its own validation and `meetingsSubdir`'s `withIntermediateDirectories: true` creation call — the same race already captured in the frontmatter `deferred` entry (broadened in pass 2); not double-counted.
  - `[false]` `[reject]` (Edge Case Hunter) TOCTOU between the collision-existence check and `AtomicWriter`'s rename — the same race already in the `deferred` entry since pass 1; not double-counted.
  - `[false]` `[reject]` (Edge Case Hunter) `meetingsSubdir` empty-string and `..`-traversal validation — reaffirms passes 1-2: no adversarial threat model applies to a single-user-configured value.
  - `[false]` `[reject]` (Intent Alignment Auditor) `vaultPath` validation happening at call-time (inside `VaultWriter.write` itself) rather than only at launch-time (Decision 2.5's "on launch"/doctor framing) is "an extension by analogy" not directly stated for `vaultPath` the way it is for `meetingsSubdir` — reaffirms pass 1 with sharper grounding: `epics.md`'s own Story 2.3 AC explicitly lists "vault-path-missing failure path" among `VaultWriter`'s own required tests, independent of Decision 2.5's separate launch-time framing — call-time validation is squarely in this story's own AC, not just a reasonable inference from a sibling decision.
  - `[false]` `[reject]` (Intent Alignment Auditor) The "never opens an existing file" AC's named unit test is absent — same finding as Blind Hunter's, same disposition above; not double-counted.
  - `[false]` `[reject]` (Intent Alignment Auditor) The re-publish discriminator is satisfied only vacuously since no re-publish caller exists — reaffirms passes 1-2: explicitly out of scope per this spec's own Boundaries, Story 2.4's concern.
  - `[false]` `[reject]` (Intent Alignment Auditor) The collision-retry cap has no antecedent in the planning docs, introduced entirely within this review loop — reaffirms pass 2: exactly what the `bad_spec` self-correction mechanism exists for.
  - `[false]` `[reject]` (Intent Alignment Auditor) Every tension this diff found was resolved via in-loop self-correction rather than reported as "blocked," and the auditor "can't independently verify that boundary was drawn correctly" — reaffirms passes 1-2: this workflow's own `bad_spec`/`patch`/`defer` taxonomy is the sanctioned mechanism for exactly this class of discovery, external to and predating any single story's own spec artifact.

## Design Notes

**Why `write` takes `meeting: MeetingForFilename` rather than a pre-resolved filename string:** the epics AC's own illustrative signature (`write(_ markdown: String, to relativePath: String)`) reads as though the filename is already resolved by the time `VaultWriter` is called — but the *same* AC also requires `VaultWriter` to "consult `FilenameResolver` to apply the deterministic ordinal counter" when it detects a collision at write time. Those two requirements are in tension: a bare filename string gives `VaultWriter` nothing to re-derive an ordinal-suffixed alternative from. Resolving the tension in favor of the collision-handling requirement (the more specific, more heavily-tested behavior in Story 2.3's own AC list) means `VaultWriter` needs the full `MeetingForFilename` value, not just a string, so it can call `FilenameResolver.resolve(meeting:ordinal:)` itself for both the first attempt and every retry.

**Typed error shape** (matching `AtomicWriter.WriteError`'s own convention — one `enum` per domain, `Error`-conforming, cases carrying the path and reason; `maxCollisionOrdinal` added in review iteration 1, see Spec Change Log):

```swift
public enum VaultWriter {
    public enum WriteError: Error {
        case vaultPathMissing(path: String)
        case vaultPathNotWritable(path: String)
        case meetingsSubdirIsNotADirectory(path: String)
        case meetingsSubdirNotWritable(path: String)
        case meetingsSubdirCreationFailed(path: String, underlying: Error)
        /// `path` is the *last* candidate tried (i.e. the one at `maxOrdinal`),
        /// not a next-attempted or otherwise special path — spell this out in
        /// the case's own doc comment so a caller formatting this into a log
        /// message doesn't have to guess.
        case collisionRetriesExhausted(path: String, maxOrdinal: Int)
    }

    /// A high, effectively-never-hit ceiling — same-day, same-slug collisions
    /// this deep are not a realistic scenario; this cap exists so a
    /// FilenameResolver defect or data-corruption scenario fails fast with a
    /// clear error instead of spinning forever, matching every other failure
    /// mode in this function. Deliberately not `private`: a test asserting
    /// `.collisionRetriesExhausted` behavior needs to reference this exact
    /// value via `@testable import` rather than hardcoding a duplicate
    /// literal that could silently drift from the real cap.
    static let maxCollisionOrdinal = 1000

    /// Throws `VaultWriter.WriteError` for a validation/collision failure, or
    /// propagates `AtomicWriter.WriteError` from the underlying write.
    public static func write(
        _ markdown: String,
        meeting: MeetingForFilename,
        vaultPath: URL,
        meetingsSubdir: String,
    ) throws -> URL {
        // 1. Validate vaultPath exists AS A DIRECTORY + is writable, else throw
        //    .vaultPathMissing / .vaultPathNotWritable. ("Exists as a
        //    directory" is the actual check — a vaultPath that exists but is
        //    a plain file must also throw .vaultPathMissing, not fall
        //    through.)
        // 2. Resolve vaultPath/meetingsSubdir: if missing, auto-create it
        //    with withIntermediateDirectories: true (meetingsSubdir may
        //    itself be a nested path per Decision 2.5's own "inbox/Meetings/"
        //    example — every missing component under it must be created);
        //    else validate it's a writable directory, else throw. The
        //    residual, narrow race where vaultPath itself could in principle
        //    be recreated this way is accepted — see the frontmatter
        //    deferred entry for why fixing it precisely isn't worth losing
        //    nested-meetingsSubdir support over.
        // 3. var ordinal: Int? = nil (the bare, no-suffix filename tried
        //    first); loop: candidate = FilenameResolver.resolve(meeting:
        //    meeting, ordinal: ordinal); if nothing exists at candidate,
        //    stop and use it; else bump ordinal to the next value
        //    deterministically (never random) and retry -- throw
        //    .collisionRetriesExhausted once the next value would exceed
        //    maxCollisionOrdinal.
        // 4. AtomicWriter.write(Data(markdown.utf8), to: the found candidate)
        // 5. return that candidate URL
    }
}
```

**Out of scope, deliberately:** a re-publish-specific entry point (Story 2.4's rerun-suffix construction) is not designed here. When Story 2.4 is planned, it may call this same `write` function (a rerun filename is already date+ordinal-unique enough that a collision here would be a genuine anomaly worth surfacing, not something to special-case away), or it may need a narrower variant — that decision belongs to Story 2.4's own spec, once it exists, not to speculative design here.

**Also out of scope, deliberately (review iteration 1):** true collision-safe atomicity against a concurrent writer racing between this function's existence check and `AtomicWriter`'s own `rename(2)` call. `AtomicWriter`'s own doc comment already states callers are responsible for serializing writes to a given path — it doesn't offer an exclusive-create mode, and adding one would mean modifying that already-shipped, already-tested Story 1.2 primitive (or building new cross-process serialization machinery), neither of which this story's scope covers. See the frontmatter `deferred` entry for the full reasoning. Similarly out of scope: validating `meetingsSubdir` against path traversal (`..`, absolute paths) — it's a user-configured value on a single-user machine the user already has full filesystem access to, the same "trust the caller/config" boundary this epic applies to `vaultPath` itself and every pre-resolved field in `MeetingForFrontmatter`/`MeetingForFilename`.

## Verification

**Commands:**
- `swift test --filter PersistTests` -- expected: all `VaultWriterTests` pass alongside the existing `FrontmatterRendererTests`/`FilenameResolverTests`.
- `swift build` -- expected: clean build, no new external dependency.
- `swiftformat --lint .` and `swiftlint lint --strict --config .swiftlint.yml .` -- expected: 0 violations, including confirmation that the existing `atomic_writer_bypass` rule doesn't fire against `VaultWriter.swift`'s own `AtomicWriter.write(...)` call site. **Pass `--config .swiftlint.yml` explicitly when running swiftlint from inside this worktree** -- it is nested inside the main checkout, and swiftlint's default config discovery can silently pick up the wrong, outer `.swiftlint.yml` otherwise (confirmed during this story's own implementation; the worktree-local `atomic_writer_bypass` exclusion for `VaultWriterTests.swift` only takes effect with the flag).

## Auto Run Result

**Summary:** Implemented `Persist/VaultWriter.swift`, composing `Core/AtomicWriter` to publish rendered markdown into the vault: validates `vaultPath` (never auto-created), resolves and auto-creates `meetingsSubdir` (including nested paths like Decision 2.5's own `"inbox/Meetings"` example), and resolves a collision-free filename via `FilenameResolver`'s bounded ordinal retry. Three review passes were needed — two `bad_spec` corrections and one `patch` — each documented in full in the Spec Change Log and Review Triage Log above.

**Files changed:**
- `Sources/Persist/VaultWriter.swift` -- new. `VaultWriter.write(_:meeting:vaultPath:meetingsSubdir:) throws -> URL`.
- `Tests/PersistTests/VaultWriterTests.swift` -- new, 15 tests as of the final iteration, one per I/O-matrix row (count the matrix directly rather than trust a restated number, per this spec's own hard-won lesson about that number drifting three times across review passes).
- `.swiftlint.yml` -- added `VaultWriterTests.swift` to the existing `atomic_writer_bypass` exclusion list (the test file legitimately sets up raw filesystem state `VaultWriter` itself must detect, not produce) -- no new rule, matching the spec's explicit constraint.

**Review findings breakdown across 3 review passes** (full detail and every rejected finding's reasoning are in the Review Triage Log above):
- **Pass 1 → bad_spec (4 findings, 2 root causes):** an unbounded collision-retry loop could hang indefinitely instead of failing fast; `withIntermediateDirectories: true` for `meetingsSubdir` auto-creation could, in a narrow race, silently recreate a `vaultPath` that disappeared moments after its own validation. Fixed with a hard retry cap (`maxCollisionOrdinal = 1000`, a new `WriteError` case) and, at the time, `withIntermediateDirectories: false`.
- **Pass 2 → bad_spec (4 findings, 1 root cause):** pass 1's own `withIntermediateDirectories: false` fix was itself a regression — Decision 2.5's own documentation names a nested `meetings_subdir` value (`"inbox/Meetings/"`) as a supported configuration shape, and that fix broke it. Reverted to `withIntermediateDirectories: true`, accepting the narrower residual race (folded into the same `deferred` entry) rather than losing real, documented functionality. This pass also fixed a hardcoded test constant now referencing the real (`private`→internal) production value, a test cleanup-ordering bug, and several spec accuracy issues (stale test counts, stale pseudocode).
- **Pass 3 → patch (1 low-severity group + 3 unrelated low-severity spec/doc fixes):** pass 2's own rejection of "no deterministic trigger exists for testing `AtomicWriter.WriteError` propagation through `VaultWriter`" was itself wrong — a pre-created directory at `AtomicWriter`'s own temp path triggers it deterministically. Added the test via a lightweight patch (re-engaging the implementation agent directly, no full revert, since the underlying code was already correct). This pass also corrected persistent inaccuracies in the spec's own bookkeeping: two prior passes' "verdicts:" summary lines didn't match their own itemized lists (now fixed), and Design Notes' pseudocode still described an already-superseded control flow despite two earlier passes claiming to have corrected it.
- **Deferred (1 item, added to frontmatter `deferred:`):** two related TOCTOU races (collision-check-to-`AtomicWriter`-rename; `vaultPath`-deletion-during-`meetingsSubdir`-creation) — both real, both requiring either modifying the already-shipped `AtomicWriter` primitive or accepting a narrow, low-probability race matching a trade-off Decision 2.4 already accepts elsewhere.

**Follow-up review recommendation: `false`.** The final review pass (pass 3) patched only `low`-severity entries — no `high`, and fewer than two `medium`. No unverified risk remains to name beyond what's already captured in the `deferred` entry.

**Verification performed:** `swift build` and `swift test --filter PersistTests` after every implementation/re-derivation cycle (final: 15/15 `VaultWriterTests`, 48/48 `PersistTests`, 169/169 full suite); `swiftformat --lint .` and `swiftlint lint --strict --config .swiftlint.yml .` clean at every checkpoint (repo-wide, 101 files); `scripts/verify-custom-lint-rules.sh` confirmed all 6 custom rule fixtures still fire correctly, including that the new exclusion-list entry didn't blind `atomic_writer_bypass` for any other file. This agent additionally ran targeted empirical probes (throwaway test files, removed before each commit) at every review pass rather than judging plausibility from code-reading alone -- this is what caught the nested-`meetingsSubdir` regression in pass 2 and both testability corrections (`meetingsSubdirCreationFailed` in pass 2, `AtomicWriter.WriteError` propagation in pass 3) after this agent had itself initially and incorrectly judged them untestable.

**Residual risks:** the deferred TOCTOU item above; the standing caller-trust boundary this epic uses throughout (`vaultPath`/`meetingsSubdir` are assumed well-formed, not defended against adversarial values, since no adversarial threat model applies to a single-user-configured value on the user's own machine); and this worktree's own swiftlint nested-config quirk (documented in Verification above) -- not a defect in this story's code, but a genuine environment trap for whoever verifies this story's work later without the `--config` flag.
