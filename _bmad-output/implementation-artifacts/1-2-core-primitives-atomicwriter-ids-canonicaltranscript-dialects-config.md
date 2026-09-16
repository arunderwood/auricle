---
title: 'Story 1.2: Core Primitives — AtomicWriter, IDs, Dialects, Errors'
type: 'feature'
created: '2026-09-15'
status: 'done'
baseline_commit: 'ba52866a11b85c811ad0f06e3ee09f9754e62237'
route: 'dispatch'
review_loop_iteration: 0
context: ['{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `Core` has only a placeholder file. The primitives Epic 1's remaining stories (1.3–1.8) depend on — atomic writes, meeting IDs, JSON dialect rules, typed errors — don't exist yet.

**Approach:** Implement these four groups in `Sources/Core/` per epics.md's Story 1.2 ACs, replacing `ManifestPlaceholder.swift`; resolve the `MeetingIDResolver` protocol shape architecture.md defers to this story. Narrowed from epics.md's full 6-primitive "Story 1.2" by the token-budget split gate — `CanonicalTranscript`/`Config` are deferred (see deferred-work.md).

## Boundaries & Constraints

**Always:**
- `Core`'s external dependencies are `TOMLKit` and `ULID.swift` (yaslab); any further dependency is an architecture escalation, not a silent addition.
- One primary type per file, filename == type name; flat `Sources/Core/` layout.
- `AtomicWriter.write(_:to:)` is the sole filesystem-write primitive; nothing else here calls `Data.write`/`FileManager.createFile` directly.
- Typed errors: `Error`-conforming `enum`s, one per domain, associated values for context; `NSError` translated only at Apple-framework callback boundaries.

**Never:**
- Don't implement `CanonicalTranscript` or `Config` — deferred, see deferred-work.md.
- Don't implement the AR-PAT-4 CI-lint bypass-detection rule — that's Story 1.8; tests cover correctness now, grep enforcement lands later.
- `ULID.generate`/`ULID.isValid` wrap `yaslab/ULID.swift` (MIT, Foundation-optional); don't hand-roll Crockford base32 encode/decode.
- Don't touch any `Source/<Target>` other than `Core`, or any file under `App/`.

_Renegotiated 2026-09-16 via correct-course: see sprint-change-proposal-2026-09-16-ulid-dependencies.md._

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| AtomicWriter interrupted before rename | Kill simulated after temp write, before rename | Temp file present; target absent/unchanged, never partial | Caller sees temp file next run, can retry |
| AtomicWriter re-run | Second `write` to same path | Target overwritten atomically | N/A |
| Resolver: ambiguous prefix | Prefix matching 2+ known IDs | `.ambiguous([ids])` | Caller (CLI) prints list, exits 1 |
| Resolver: prefix too short (<6 chars) | 5-char input, not `current`/`last` | `.notFound` | N/A |

</frozen-after-approval>

## Code Map

- `Sources/Core/ManifestPlaceholder.swift` -- delete; replaced by real code
- `epics.md:844-889` -- authoritative ACs (only AtomicWriter/IDs/Dialects/typed-error blocks in scope)
- `architecture.md:546-556` -- `MeetingIDResolver` I/O table (full ULID / prefix≥6 / `current` / `last`)
- `architecture.md:2889,2908,2929` -- resolver protocol shape deferred to this story, resolved in Design Notes
- `architecture.md:1850` -- snake_case/camelCase dialect table
- `1-1-...md:165-186,372-395` -- Story 1.1's scope fence confirms these primitives belong here
- `Package.swift:53` -- `Core` target already declared (`TOMLKit` only), no change needed
- `Tests/CoreTests/PackageScaffoldingTests.swift` -- Story 1.1's sentinel test; delete once real tests land here

## Tasks & Acceptance

**Execution:**
- [x] `Sources/Core/AtomicWriter.swift` -- `AtomicWriter.write(_ data: Data, to path: URL) throws`, temp → fsync → rename -- NFR-R1+FR36
- [x] `Sources/Core/ULID.swift` -- ULID generation (timestamp-prefixed, Crockford base32, 26 chars), wraps `yaslab/ULID.swift` -- backs `MeetingID.generate()`
- [x] `Sources/Core/MeetingID.swift` -- `struct MeetingID` wrapping the ULID string; `MeetingID(ulid:)` (validating), `.generate()` -- AR-PAT-7
- [x] `Sources/Core/MeetingIDResolver.swift` -- `MeetingIDDataSource` protocol + `MeetingIDResolver` per Design Notes contract
- [x] `Sources/Core/Codable+Dialects.swift` -- snake_case `CodingKeys` pattern for cache-dir types; camelCase (no `CodingKeys`) for CLI types -- AR-PAT-2
- [x] `Sources/Core/Errors.swift` -- `CaptureError`/`TranscribeError`/`SummarizerError`/`PersistError`/`VerifierError`, `Error`-conforming enums with associated values -- AR-PAT-7
- [x] `Tests/CoreTests/AtomicWriterTests.swift` -- the two I/O Matrix AtomicWriter rows + a basic success-write case
- [x] `Tests/CoreTests/ULIDTests.swift` -- format + timestamp-sort-order property
- [x] `Tests/CoreTests/MeetingIDResolverTests.swift` -- all 4 input forms incl. both I/O Matrix edge cases, against a fake `MeetingIDDataSource`
- [x] `Tests/CoreTests/DialectsTests.swift` -- one round-trip test per dialect
- [x] `Tests/CoreTests/PackageScaffoldingTests.swift` -- delete, superseded by real tests above

**Acceptance Criteria:**
- [x] Given `Sources/Core/`, when `swift build && swift test --filter CoreTests` runs, then both succeed with zero warnings and all new tests pass -- verified independently: build exit 0, no Core warnings, 16/16 tests pass
- [x] Given `Sources/Core/`, when inspected, then `ManifestPlaceholder.swift` and `PackageScaffoldingTests.swift` are both gone -- verified independently

## Implementation Notes

- `Codable+Dialects.swift` implements the epics.md-authorized "documented pattern" option (two example types: `CacheArtifactDialectExample` with explicit snake_case `CodingKeys`, `CLIOutputDialectExample` with default camelCase synthesis) rather than a `SnakeCaseCodingKey` helper — Core has no real JSON contract type yet to build a generic helper against.
- `Errors.swift` cases are grounded in exact terminology found in architecture.md/epics.md where it exists (`CaptureError`, `SummarizerError`, `VerifierError`); `TranscribeError`/`PersistError` are minimal `.stageFailed(reason:)` placeholders since no case vocabulary for those domains exists anywhere in planning docs yet. `CaptureError.permissionDenied` takes `category: String` rather than a `TCCCategory` type, since `Core` cannot depend on `Permissions` and `TCCCategory` doesn't exist until Story 5.1.
- All 16 new tests pass (`swift test --filter CoreTests`); full-package `swift build`/`swift test` also pass with no regressions to other placeholder targets.

## Spec Change Log

## Review Triage Log

| # | Finding | Verdict | Route | Evidence |
|---|---------|---------|-------|----------|
| 1 | `AtomicWriter.write` has no protection against two concurrent calls targeting the same path (deterministic shared temp file) (Blind Hunter + Edge Case Hunter) | medium | patch | Verified: `temporaryURL(for:)` always returns the same `.{name}.tmp` sibling for a given target; a second concurrent `createFile` truncates the first call's in-flight temp file. No doc comment or test states the "one writer per path at a time" precondition. |
| 2 | `WriteError.createTemporaryFileFailed` carries no `errno`/underlying diagnostic, unlike every other `WriteError` case, and that failure path is untested (Blind Hunter) | low | patch | Verified: `FileManager.createFile` returns `Bool`, not throwing, so the guard-else branch has no error to capture; `errno` is available but not read. |
| 3 | Case-insensitive ID/prefix handling (`.uppercased()` in `ULID.isValid`, `MeetingID.init?`, `MeetingIDResolver.resolve`) is implemented but no test passes a lowercase input (Blind Hunter) | low | patch | Verified: grepped `MeetingIDResolverTests.swift`/`ULIDTests.swift` — all fixture IDs and resolver inputs are already-uppercase. |
| 4 | No upper bound/alphabet check on `MeetingIDResolver.resolve`'s prefix input before it reaches the data source (Blind Hunter) | false | reject | Verified: `MeetingIDDataSource` is an injected protocol: whatever bound-checking a real data source needs is that data source's own concern (Story 1.4), not this story's. Nothing in this diff mishandles oversized input — it's passed straight through to a caller-supplied implementation. |
| 5 | `Errors.swift` header comment's target list doesn't map 1:1 to the error-enum names (e.g. `TranscribeError` vs. target `TranscriberInterface`) (Blind Hunter) | false | reject | Read the comment in context: it lists the *placeholder targets relevant to each domain* to justify one shared file, not a claimed strict enum-to-target ownership rule. No reader-facing ambiguity in the actual (unambiguous) enum declarations. |
| 6 | The 5 new error enums aren't `Sendable`, unlike `MeetingID` added in the same diff (Blind Hunter) | low | patch | Verified: `MeetingID` explicitly conforms to `Sendable`; `CaptureError`/`TranscribeError`/`SummarizerError`/`PersistError`/`VerifierError` do not, despite carrying only `Sendable`-safe associated values (`String`). |
| 7 | `Codable+Dialects.swift`'s two example types are illustrative only, not consumed by real code, with no tracking entry for eventual removal (Blind Hunter) | false | reject | Verified: this is epics.md AC4's explicitly authorized "documented pattern" alternative to a generic helper; both types are internal (no `public`), and `DialectsTests.swift` exercises them per the AC's own round-trip-test requirement. Already explained in Implementation Notes. |
| 8 | `sprint-status.yaml`'s `last_updated` (2026-09-15) is now one day stale (session crossed midnight) (Blind Hunter) | low | patch | Verified: field equaled the actual date at edit time; now stale purely from session duration, not from a code defect. Trivial to correct. |
| 9 | `sprint-status.yaml` moves story 1-2 directly `backlog` → `in-progress`, skipping the `ready-for-dev` status its own header comments define (Blind Hunter) | medium | defer | Verified: this is `sync-sprint-status.md`'s own designed behavior (target_status is set directly), not something this story's content caused — same root cause as the tracking-vocabulary mismatch already logged in `deferred-work.md` for Story 1.1, and will recur for every future story through this workflow. |
| 10 | `epic-1-context.md`'s Story 1.2 entry still reads "AtomicWriter, IDs, CanonicalTranscript, Dialects, Config" with no note that `CanonicalTranscript`/`Config` were split out (Blind Hunter) | medium | patch | Verified: this context file is the *primary* planning context future Epic 1 stories load (per step-1's caching rule) — a future story's investigation could wrongly assume `CanonicalTranscript` already exists. |
| 11 | `MeetingIDResolver` isn't named in the spec's Boundaries & Constraints "Always" section as a no-bypass primitive, though epics.md's AR-PAT-4 list treats it identically to `AtomicWriter` (Blind Hunter) | n/a | reject | Its only possible fix is editing `<frozen-after-approval>` text in this build's spec, which is out of scope for triage; no code-level bypass is possible today since no caller of `MeetingIDResolver` exists yet. |
| 12 | `ULID.generate`'s `UInt64(now.timeIntervalSince1970 * 1000)` traps on an extreme/out-of-range `Date` (Edge Case Hunter) | low | patch | Verified: `Double` → `UInt64` conversion traps (doesn't clamp) when the value exceeds `UInt64.max`; reachable only via an explicitly-passed extreme `Date`, but the fix is a one-line clamp. |
| 13 | `MeetingIDResolver.resolve` treats `current`/`last` as case-sensitive exact matches — `"Current"` falls through to prefix search (Edge Case Hunter) | false | reject | Verified against epics.md: the AC specifies the literal lowercase strings `current`/`last` as the accepted keyword forms, with no case-insensitivity requirement stated (unlike the ULID prefix rule, which explicitly is case-insensitive). Implementation matches spec as written. |

## Design Notes

**`MeetingIDResolver` protocol split** (deferred to this story by architecture.md): `Core` can't depend on `State`/GRDB, so the resolver takes an injected protocol instead of querying SQLite directly. Real GRDB conformance lands with Story 1.4; this story's tests use a fake.

```swift
public protocol MeetingIDDataSource {
    func meetingIDs(matchingPrefix prefix: String) -> [MeetingID]
    func currentMeetingID() -> MeetingID?   // active capture (state == "recording")
    func lastMeetingID() -> MeetingID?      // highest created_at
}
public enum MeetingIDResolution: Equatable { case resolved(MeetingID), ambiguous([MeetingID]), notFound }
public struct MeetingIDResolver {
    private let dataSource: MeetingIDDataSource
    public init(dataSource: MeetingIDDataSource) { self.dataSource = dataSource }
    public func resolve(_ input: String) -> MeetingIDResolution { ... }
}
```

**Five typed-error enums share one `Errors.swift`** (AR-PAT-1 allows coupled secondary types per file): each domain's target is still a placeholder, so splitting into five near-empty files adds nothing yet.

## Verification

**Commands:**
- `swift build && swift test --filter CoreTests` -- expected: exit 0, all tests pass
- `grep -rn "Data.write(to:\|String.write(to:\|FileManager.default.createFile" Sources/Core/` -- expected: only matches inside `AtomicWriter.swift`
