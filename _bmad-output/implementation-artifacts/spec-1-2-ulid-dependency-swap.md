---
title: 'ULID generation: wrap yaslab/ULID.swift instead of hand-rolled encoding'
type: 'refactor'
created: '2026-09-16'
status: 'done'
route: 'oneshot'
review_loop_iteration: 0
context: ['{project-root}/_bmad-output/planning-artifacts/sprint-change-proposal-2026-09-16-ulid-dependencies.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `Sources/Core/ULID.swift`'s `generate()` hand-rolls Crockford base32 timestamp/randomness encoding via manual bit-shifting. Review already caught one bug here (`Double → UInt64` traps on an extreme `Date` instead of clamping — since patched). This is exactly the class of bug a vetted library avoids. Story 1.2's frozen intent has been renegotiated (`sprint-change-proposal-2026-09-16-ulid-dependencies.md`) to allow `yaslab/ULID.swift` (MIT, 134★, actively maintained) as `Core`'s second dependency alongside `TOMLKit`.

**Approach:** Add `yaslab/ULID.swift` to `Package.swift` and wire it into the `Core` target. Replace `ULID.generate(now:)`'s internal bit-manipulation with `ULID(timestamp: now).ulidString` from the library (confirmed: its `init(timestamp: Date = Date())` supports the same deterministic-`now` testability our current tests rely on, and its output is byte-identical Crockford base32 — timestamp-prefixed, lexically sortable). **Leave `ULID.isValid(_:)` untouched** — it keeps its current strict character-membership check rather than delegating to the library's `init?(ulidString:)`, because the library's decoder Crockford-alias-folds (`I`/`L`→`1`, `O`→`0`), which would flip the existing `isValidRejectsWrongLengthAndDisallowedCharacters` test (asserts a string containing `I` is rejected) and loosen `MeetingID`'s validation. That leniency is a real, separately-flagged improvement (noted in the sprint change proposal as a deferred gap) — not something to fold silently into a swap whose whole point is zero behavior change.

</frozen-after-approval>

## Implementation Notes

- **Naming collision discovered mid-implementation, not anticipated by the sprint-change-proposal's sketch.** `yaslab/ULID.swift`'s module is itself named `ULID`, colliding with `Core`'s own `public enum ULID`. From inside that enum's body, an unqualified `ULID.ULID(...)` resolves to `Self`, not the module, and errors "type 'ULID' has no member 'ULID'" — Swift favors the local module-level type over the imported module name for an unqualified identifier, with no fallback. SwiftPM's `moduleAliases` (tried first) does not fix this: it resolves *cross-dependency* module-name collisions in the build graph, not a local-type-vs-imported-module collision, and the compiler explicitly rejected importing under the alias ("cannot refer to module as 'ULIDLib'... use 'ULID' instead").
- **Fix:** renamed `Core`'s own type from `ULID` to `ULIDFormat` (file renamed `Sources/Core/ULID.swift` → `Sources/Core/ULIDFormat.swift`, matching the "filename == type name" convention; test file renamed to match). This is the only clean fix that avoids adding a new SwiftPM target (which AR-INIT-5's fixed target list would make its own architecture escalation, well beyond this change's scope). Confirmed contained: `ULID` (the type) had exactly two real call sites outside its own file, both in `MeetingID.swift`; `MeetingIDResolver.swift` never referenced the type directly. `MeetingID`'s and `MeetingIDResolver`'s own public signatures are unchanged.
- **Confirmed by reading the library's source directly** (not just its README): `init(timestamp: Date = Date())` supports the deterministic-`now` parameter our tests need; `.ulidString` output is standard big-endian-timestamp-prefixed Crockford base32, so lexical sort order is preserved with no encoding changes.
- **Correction to the sprint-change-proposal's stated "known gap":** that document said alias-folding (`I`/`L`→`1`, `O`→`0`) was a gap this swap does *not* fix. Reading the library's actual base32 decode table shows it already does this folding on `init?(ulidString:)`. `ULIDFormat.isValid` deliberately does **not** use the library's decoder for exactly this reason — it keeps its own strict character-membership check, so this swap stays a pure internal-implementation change with zero observable behavior difference (verified: the existing test asserting a string containing `I` is rejected still passes unmodified).
- **Verified:** `swift build` (whole package) and `swift test --filter CoreTests` (19 tests, including all `MeetingIDResolverTests` and the renamed `ULIDFormatTests`) pass unmodified — no test assertions needed to change.
- **Review caught a real regression before it shipped:** the library's `init(timestamp:)` does its own `Double -> UInt64` conversion with no clamping, silently reintroducing the exact pre-1970 crash Story 1.2's original review had already found and fixed in the hand-rolled encoder. Patched by clamping `now` to a non-negative millisecond offset in `ULIDFormat.generate(now:)` before constructing the library's `ULID`, and added `pre1970TimestampDoesNotTrap` to `ULIDFormatTests.swift`. 20 `CoreTests` pass after the fix.
- Also corrected in this pass (not frozen-block edits): `epic-1-context.md` and `architecture.md` both called the library "Foundation-optional" — its two source files unconditionally `import Foundation`, no `#if canImport` guard, so this was factually wrong; reworded to "no transitive third-party deps beyond Foundation." `architecture.md`'s file-tree comments still named the pre-rename `ULID.swift`/`ULIDTests.swift`; updated to `ULIDFormat.swift`/`ULIDFormatTests.swift`.

## Review Triage Log

Blind Hunter (context-free, N=4 minimum per `min(floor(sqrt(12.6 KB)+1), 10)`), 6 findings:

| # | Finding | Verdict | Route | Evidence |
|---|---|---|---|---|
| 1 | `ULIDFormat.generate(now:)` reintroduces the pre-1970 `Double → UInt64` trap Story 1.2's original review already fixed | high | patch | Confirmed by reading the library's source: `init(timestamp:)` computes `UInt64(timestamp.timeIntervalSince1970 * 1000.0)` with no clamp. Fixed by clamping in `ULIDFormat.generate(now:)` before constructing the library type. |
| 2 | No regression test covered the pre-1970 case | high (same group as #1 — same root cause) | patch | Same fix commit adds `pre1970TimestampDoesNotTrap`. |
| 3 | "Foundation-optional" mischaracterizes the dependency | low | patch | Verified: both of the library's source files unconditionally `import Foundation`. Reworded in `epic-1-context.md` and `architecture.md`. |
| 4 | `architecture.md`'s file-tree comments still named the pre-rename `ULID.swift`/`ULIDTests.swift` | low | patch | Caused directly by this change's mid-implementation rename to `ULIDFormat`; updated both lines. |
| 5 | Spec's frozen Intent calls the library "actively maintained" | low | defer | Verified via GitHub API: latest tag (1.3.1) is from 2024-08-11; not abandoned (recent commit activity, not archived) but "actively maintained" overstates release cadence. Left as-is — inside `<frozen-after-approval>`, which this step cannot edit; logged in `deferred-work.md`. |
| 6 | No golden/fixed-output test pins the exact wire format against a known input | low | defer | Real gap, low likelihood of ever mattering (would require a semver-compatible release that changes output format, which would itself be a bug in the dependency). Logged in `deferred-work.md` as a cheap future hardening, not blocking. |
