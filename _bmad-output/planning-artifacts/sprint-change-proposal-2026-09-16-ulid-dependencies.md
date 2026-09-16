---
title: 'Sprint Change Proposal: ULID generation and the dependency-avoidance pattern behind it'
date: '2026-09-16'
status: 'approved'
scope: 'moderate'
---

## 1. Issue Summary

Story 1.2 ("Core Primitives — AtomicWriter, IDs, CanonicalTranscript, Dialects, Config") hand-rolls Crockford base32 ULID generation in `Sources/Core/ULID.swift`, under a self-imposed constraint — "Don't pull in a third-party ULID package — Foundation only" — that appears nowhere in the PRD, epics.md, or architecture.md. It was invented at story-implementation time and frozen into that story's intent block without architecture-level review.

The maintainer flagged this during a routine question: is there a native facility or well-supported package for ULID generation, to avoid the bug and security surface of a hand-rolled implementation? There isn't a native ULID facility (Foundation has no ULID type), but there is a mature, narrowly-scoped OSS package (`yaslab/ULID.swift`, MIT, 134★, actively maintained). The codebase is not otherwise dependency-averse — `Package.swift` already depends on WhisperKit, GRDB.swift, swift-argument-parser, and TOMLKit.

**Evidence the hand-roll is already lossy**, discovered during this review:
- Story 1.2's own review already caught and patched a bug: `Double → UInt64` traps on an extreme `Date` instead of clamping.
- `ULID.isValid` does not apply Crockford's alias-folding (`I`/`L`→`1`, `O`→`0`), so a user-mistyped or OCR'd ID can fail `MeetingIDResolver`'s prefix lookup silently.
- There is no monotonic counter for same-millisecond generation, so the "timestamp-sortable" property in the Story 1.2 AC can silently break for two IDs minted in the same millisecond.

**Broader pattern**: the same shape of decision — a solved, well-specified problem (an encoding, a file format, a standard protocol) hand-rolled with no documented rationale — recurs in three not-yet-started stories:

| Story | Status | Hand-rolled | Native/library answer |
|---|---|---|---|
| 5.2 (AudioMixer) | backlog | 44.1/48kHz→16kHz resample + mono mix | `AVAudioConverter` (naive decimation aliases and quietly degrades transcription accuracy) |
| 5.3 (WAVWriter) | backlog | RIFF/WAV header construction | `AVAudioFile` — already used for *reading* elsewhere in this same plan |
| 2.1 / 2.5 (FrontmatterRenderer) | backlog | YAML frontmatter render + version-aware parse | `Yams` — hand-written YAML escaping around arbitrary calendar-event titles (colons, `[[wikilinks]]`, emoji) sits on the app's core vault contract |

Two adjacent candidates were investigated and **ruled out** as not needing a change:
- The Anthropic HTTP client: no mature Swift SDK exists (best community option is 18★, single-maintainer) — the planned thin `URLSession` wrapper is the correct choice as specified.
- Google OAuth/PKCE: the crypto (SHA-256 + base64url) is ~10 lines over CryptoKit and doesn't warrant a library; the only actionable note is that the browser leg should use `ASWebAuthenticationSession` rather than anything custom, which is worth a story-level note when 3.10 is drafted but isn't part of this proposal's scope.

## 2. Impact Analysis

- **Epic impact**: None require resequencing or restructuring. Epic 1's Story 1.2 (status `review`, not yet finalized) is amended in place. Epics 2 and 5 get architecture-level guidance added *before* their stories reach implementation-artifact drafting, at zero rollback cost since no code exists yet for those stories.
- **Story impact**: Story 1.2's frozen "Boundaries & Constraints" block is renegotiated (it is explicitly human-owned intent, designed to be reopened this way). No other story files exist yet for the affected epics.
- **Artifact conflicts**:
  - PRD: none — requirement-level, implementation-approach-agnostic.
  - epics.md: none — the relevant acceptance criteria (Story 1.2, 5.2, 5.3, 2.1, 2.5) already describe observable behavior/format, not implementation approach.
  - architecture.md: three edits — external-dependencies list, a new "Dependency Discipline" principle under Process Patterns, and file-tree comment updates.
  - UX spec: none — pure implementation detail, no user-facing change.
  - `Package.swift`: one new dependency added now (`ULID.swift`, wired into `Core`); `Yams` is named in architecture.md now but its `Package.swift` entry is deferred to when Story 2.1 is actually drafted, to avoid an unused dependency sitting in the manifest.
- **Technical impact**: `Sources/Core/ULID.swift` is rewritten to wrap the library; `MeetingID`/`MeetingIDResolver`'s public surface and `Tests/CoreTests/ULIDTests.swift` are unaffected, since both assert the observable contract (26-char Crockford, timestamp-sortable, case-insensitive) rather than the internal encoding.

## 3. Recommended Approach

**Direct Adjustment (Option 1).** Story 1.2 is still in `review`, not `done`, so amending it is a normal revision, not a rollback of accepted work. No epic restructuring, no MVP scope change. Effort: **Low** (one file rewrite, one dependency addition, three documentation edits). Risk: **Low** — the public API surface consumed by `MeetingID`/`MeetingIDResolver` is preserved, and the library's output format is spec-identical (still 26-char Crockford base32).

Rollback (Option 2) was considered and rejected — there's nothing to roll back to; the fix is additive to the same story. MVP review (Option 3) doesn't apply; no requirement or scope is affected.

The root-cause fix — the new "Dependency Discipline" principle in architecture.md — is included specifically so this doesn't recur when Stories 5.2, 5.3, 2.1, and 2.5 reach implementation-artifact drafting.

## 4. Detailed Change Proposals

### 4.1 Story document — `_bmad-output/implementation-artifacts/1-2-core-primitives-atomicwriter-ids-canonicaltranscript-dialects-config.md`

**Section:** Boundaries & Constraints (frozen-after-approval block)

```diff
 **Always:**
- - `Core`'s only external dependency stays `TOMLKit`; any new dependency is an architecture escalation, not a silent addition.
+ - `Core`'s external dependencies are `TOMLKit` and `ULID.swift` (yaslab); any further dependency is an architecture escalation, not a silent addition.

 **Never:**
 - Don't implement `CanonicalTranscript` or `Config` — deferred, see deferred-work.md.
 - Don't implement the AR-PAT-4 CI-lint bypass-detection rule — that's Story 1.8; tests cover correctness now, grep enforcement lands later.
- - Don't pull in a third-party ULID package — Foundation only.
+ - `ULID.generate`/`ULID.isValid` wrap `yaslab/ULID.swift` (MIT, Foundation-optional); don't hand-roll Crockford base32 encode/decode.
 - Don't touch any `Source/<Target>` other than `Core`, or any file under `App/`.
```

Also append: `_Renegotiated 2026-09-16 via correct-course: see sprint-change-proposal-2026-09-16-ulid-dependencies.md._`

Task list line updated: `[x] Sources/Core/ULID.swift -- ULID generation (timestamp-prefixed, Crockford base32, 26 chars), Foundation only -- backs MeetingID.generate()` drops the "Foundation only" clause.

**Rationale:** This is the one frozen, human-owned-intent document, so it must explicitly record the override.

### 4.2 `Package.swift`

```diff
     dependencies: [
         .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
         .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
         .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
         .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
+        .package(url: "https://github.com/yaslab/ULID.swift.git", from: "1.3.1"),
     ],
     targets: [
         // === Cross-cutting ===
-        .target(name: "Core", dependencies: [.product(name: "TOMLKit", package: "TOMLKit")], path: "Sources/Core"),
+        .target(
+            name: "Core",
+            dependencies: [
+                .product(name: "TOMLKit", package: "TOMLKit"),
+                .product(name: "ULID", package: "ULID.swift"),
+            ],
+            path: "Sources/Core"
+        ),
```

Confirm the product name (`ULID`) against the library's current `Package.swift` at implementation time.

### 4.3 `architecture.md`

**External dependencies list** (`Technical Constraints & Dependencies`, ~line 84):

```diff
 - **swift-argument-parser** — CLI interface (NFR-I7 binding contract).
+ - **ULID.swift** (yaslab, Swift Package) — Crockford base32 ULID generation for `MeetingID`. Foundation-optional, MIT.
+ - **Yams** (jpsim, Swift Package) — YAML encode/decode for vault frontmatter (`FrontmatterRenderer`). Avoids hand-written YAML escaping around arbitrary calendar-event titles.
 - **Sparkle [v1.1]** — auto-update, EdDSA-signed appcasts.
```

**New subsection in Process Patterns** (after "Helper Discipline", before "Atomic-Write Enforcement", ~line 2013):

```diff
 The helpers have one implementation, one test, one set of edge-case decisions. Reinventing them in stage code creates inconsistency and reopens fixed bugs.

+#### Dependency Discipline (prefer solved-problem libraries)
+
+For a well-specified, general-purpose problem — an encoding (base32, base64), a container/file format (WAV, YAML), a standard protocol (OAuth/PKCE) — default to a native Apple framework or an established OSS package, not a hand-rolled implementation. `AVAudioFile`/`AVAudioConverter` for audio file I/O and resampling, `Yams` for YAML, `ULID.swift` for ULIDs are the concrete defaults for this project.
+
+A hand-rolled implementation of a solved problem needs a documented reason at its point of use (a real constraint a library doesn't meet — e.g. `AtomicWriter`'s `fsync`-before-rename requirement, which Foundation's `.atomic` write option doesn't provide). "No library was evaluated" is not a reason. This still applies within `Core`: a dependency there is an escalation to name and justify, not a default to avoid.
+
 #### Atomic-Write Enforcement (Reinforcing #3 from Cross-Cutting Concerns)
```

**File-tree comments** (`Complete Project Directory Structure`):

```diff
- │   │   └── ULID.swift                     # ULID generation (Crockford base32)
+ │   │   └── ULID.swift                     # ULID generation, wraps yaslab/ULID.swift
```
```diff
- │   │   ├── AudioMixer.swift               # mic + system audio → mono 16kHz PCM (Dec 1.4)
- │   │   ├── WAVWriter.swift                # PCM16 WAV file writer
+ │   │   ├── AudioMixer.swift               # mic + system audio → mono 16kHz PCM via AVAudioConverter (Dec 1.4)
+ │   │   ├── WAVWriter.swift                # PCM16 WAV file writer via AVAudioFile
```
```diff
- │   │   ├── FrontmatterRenderer.swift      # data → markdown (with the Dec 2.2 schema)
+ │   │   ├── FrontmatterRenderer.swift      # data → markdown via Yams (with the Dec 2.2 schema)
```

### 4.4 `Sources/Core/ULID.swift` (implementation task)

```diff
 import Foundation
+import ULID

-/// Crockford base32 ULID generation, Foundation-only (no third-party ULID
-/// package). A ULID is 26 characters: a 48-bit millisecond timestamp encoded
-/// as the first 10 characters — so lexical string order matches creation
-/// order — followed by 16 characters of random entropy.
+/// Crockford base32 ULID generation, wrapping `yaslab/ULID.swift`. A ULID is
+/// 26 characters: a 48-bit millisecond timestamp encoded as the first 10
+/// characters — so lexical string order matches creation order — followed
+/// by 16 characters of random entropy.
 public enum ULID {
-    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
-    private static let alphabetSet = Set(alphabet)
-
     public static func generate(now: Date = Date()) -> String {
-        let millis = now.timeIntervalSince1970 * 1000
-        let clamped = min(max(0, millis), Double(UInt64.max))
-        return encodeTimestamp(UInt64(clamped)) + encodeRandomness()
+        SwiftULID.ULID(timestamp: now).ulidString
     }

     public static func isValid(_ string: String) -> Bool {
-        guard string.utf8.count == 26 else { return false }
-        return string.uppercased().allSatisfy { alphabetSet.contains($0) }
+        SwiftULID.ULID(ulidString: string) != nil
     }
-
-    // encodeTimestamp / encodeRandomness / encodeBase32 -- removed, library-owned
 }
```

Exact library type/initializer names (`SwiftULID` above is a placeholder guess) must be confirmed against the library's current API at implementation time.

**Test impact:** `Tests/CoreTests/ULIDTests.swift` unchanged — it asserts the observable contract, which the library must still satisfy. `MeetingID.swift`/`MeetingIDResolver.swift` unchanged.

**Known gap not fixed by this change** (deliberate deferral, not a miss): no monotonic same-millisecond counter, no Crockford alias-folding on parse (`I`/`L`/`O` → `1`/`1`/`0`). Both are identical to today's behavior. Worth a follow-up story if either property is wanted later.

## 5. Implementation Handoff

**Scope classification: Moderate** — one in-review story amended, one architecture document updated, no epic/PRD restructuring.

- **Developer agent**: implement 4.2 (`Package.swift`) and 4.4 (`Sources/Core/ULID.swift`), confirming the library's actual public API against 4.4's placeholder names; run `Tests/CoreTests/ULIDTests.swift` and `MeetingIDResolverTests.swift` to confirm no regression.
- **Product Owner / Developer**: apply 4.1 (story document renegotiation) and 4.3 (architecture.md) directly — both are documentation-only edits, no code review needed beyond normal doc review.
- **No PM/Architect escalation needed** — architecture.md's own escalation bar ("any new dependency is an architecture escalation, not a silent addition") is satisfied by this proposal itself.

**Success criteria:** `swift build` and `swift test` pass with the new dependency; `ULID.generate()`/`ULID.isValid()` produce identical externally-observable behavior to today (same tests pass); Story 1.2's frozen intent block reflects the renegotiated constraint; architecture.md's Dependency Discipline principle is in place before Stories 5.2/5.3/2.1/2.5 reach story-drafting.
