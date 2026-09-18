---
title: 'CacheArtifactWriter: cache-dir JSON writer'
type: 'feature'
created: '2026-09-17'
status: 'done'
baseline_revision: '63c8a5d1327bfa15e3121cfd20ffcb14508861d1'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** AR-PIPE-4 and architecture.md's Core-primitives table require `CacheArtifactWriter` (cache-dir JSON writes, `schema_version` injection, 0600 permissions), but it was never built. Story 1.2 bundled it with Core's other primitives, silently dropped it without a `deferred-work.md` entry, and Story 3.7 (Summarize Stage Entry Point) now needs it to write `summary.json` with nothing to call.

**Approach:** Add `Sources/Core/CacheArtifactWriter.swift`, a thin wrapper around `AtomicWriter` following the same "validate/prepare, then delegate the byte-write" shape `VaultWriter` already uses: resolve `~/Library/Caches/com.auricle.app/<meeting-id>/`, create it if missing, encode the caller's value, merge in a top-level `schema_version`, write via `AtomicWriter.write`, then chmod the result to 0600.

## Boundaries & Constraints

**Always:**
- `AtomicWriter.write(_:to:)` is the only byte-write call; this file only prepares the directory, the encoded `Data`, and post-write permissions.
- One primary type per file (`Sources/Core/CacheArtifactWriter.swift`), matching `AtomicWriter.swift`/`VaultWriter.swift`'s enum-namespace + nested `WriteError` shape.
- `schema_version` is injected by this writer, not declared as a property on caller types — cache artifact types keep their own snake_case `CodingKeys` per `Codable+Dialects.swift` and know nothing about versioning.

**Never:**
- Don't add a read-side counterpart (epics.md:2936's future `diarization_suggestions.json` reader) — that belongs to whichever story implements `ReviewDiarization`'s AI-suggestion consumption.
- Don't touch CLI dispatch, `CalendarSource`, or glossary building (Stories 3.10/3.12) — out of scope here.
- Don't enforce cache-dir immutability (transcript.json/diarization.json's "immutable post-write" contract, Decision 5.3) inside this primitive — that's a pipeline-level discipline (which stages call `write` and when), the same way `AtomicWriter.write` itself permits overwrite-in-place and leaves serialization-per-path to callers.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fresh meeting, first artifact | No `<meeting-id>/` directory yet | Directory created, `<name>` written with `schema_version` merged in, permissions 0600 | No error expected |
| Rerun on same path | `<meeting-id>/<name>` already exists | Atomically overwritten with new content/`schema_version` | No error expected |
| Value encodes to a JSON array/scalar | Caller passes a non-object `Encodable` | No file written | `.notATopLevelJSONObject` |
| Directory creation fails | e.g. path collides with a non-directory file | No write attempted | `.directoryCreationFailed(path:underlying:)` |
| Underlying atomic write fails | e.g. parent removed mid-flight | Propagates the primitive's own error, un-wrapped | `AtomicWriter.WriteError` (not wrapped) |

</intent-contract>

## Code Map

- `Sources/Core/AtomicWriter.swift` -- the sole write-temp/fsync/rename primitive this wraps; `write(_:to:)` and `temporaryURL(for:)` are its full public surface, no directory-creation or permissions handling of its own.
- `Sources/Persist/VaultWriter.swift` -- the existing "higher-level writer composing on `AtomicWriter`" precedent (architecture.md:2052): enum namespace, nested `WriteError`, validate/create-directory then delegate to `AtomicWriter.write`. `CacheArtifactWriter` mirrors this shape.
- `Sources/State/DatabasePoolFactory.swift:13-23` -- precedent for splitting "resolve the production path under a fixed `~/Library/.../com.auricle.app/` root" into its own function (`productionDatabasePath()`) separate from the operation that uses it, so tests can call the resolver directly without mocking.
- `Sources/Core/MeetingID.swift` -- `id.rawValue` is the path segment; always a 26-char Crockford base32 ULID, safe unescaped in a path.
- `Sources/Core/Codable+Dialects.swift` -- cache-dir artifacts are the snake_case dialect; caller types declare their own `CodingKeys`, this writer does not transform casing.
- `_bmad-output/planning-artifacts/architecture.md:2032` (Core-primitives table row), `:2215` (illustrative call shape, no `schemaVersion` param shown -- described as minimum contract, not full spec), `:2264` (file location).
- `_bmad-output/planning-artifacts/epics.md:255` (AR-PIPE-4: cache-dir layout, immutability, `schema_version`, 0600, atomic writes).
- `_bmad-output/implementation-artifacts/deferred-work.md:13-19` -- confirms Story 1.2 only logged `CanonicalTranscript`/`Config` as deferred; `CacheArtifactWriter` was the un-logged sixth primitive.

## Tasks & Acceptance

**Execution:**
- `Sources/Core/CacheArtifactWriter.swift` -- add `CacheArtifactWriter` enum with `write(_:for:named:schemaVersion:)` and `cacheDirectory(for:)` -- implements AR-PIPE-4's writer per the Intent's approach.
- `Tests/CoreTests/CacheArtifactWriterTests.swift` -- cover the I/O matrix above (schema_version injection + dialect fields preserved, directory auto-creation, 0600 permissions, no leftover temp file, rerun overwrite, non-object encode failure).

**Acceptance Criteria:**
- Given a fresh `MeetingID` with no existing cache directory, when `CacheArtifactWriter.write(artifact, for: id, named: "transcript.json", schemaVersion: 1)` is called, then `~/Library/Caches/com.auricle.app/<id>/transcript.json` exists, decodes to the original artifact's fields, and additionally carries `"schema_version": 1` at the top level.
- Given a file already written to that path, when `write` is called again for the same `id`/`name`, then the file is atomically replaced (no leftover `.transcript.json.tmp`) and reflects only the new content.
- Given a successful write, when the file's POSIX permissions are inspected, then they equal `0o600`.
- Given an `Encodable` value that does not encode to a JSON object (e.g. an array), when `write` is called, then it throws `CacheArtifactWriter.WriteError.notATopLevelJSONObject` and writes nothing.

## Design Notes

`schema_version` injection uses a `JSONEncoder` → `JSONSerialization` round-trip (encode the value, parse to `[String: Any]`, add `"schema_version"`, re-serialize) rather than a custom `Encoder`/dynamic `CodingKey` type. This keeps every cache-artifact model type free of a `schemaVersion` property while still landing the field at the top level next to the type's own snake_case keys -- and it's the simplest correct option, since every artifact this writer handles is a JSON object by construction (a struct/dictionary), never a bare array or scalar.

No `cacheRoot` override parameter: architecture.md:2215's illustrative call (`write(transcript, for: id, named: "transcript.json")`) takes no path argument, and per project memory the cache dir is machine-managed (not user-editable), so it's resolved internally via `cacheDirectory(for:)` rather than injected. Tests isolate themselves by generating a fresh `MeetingID.generate()` per test and removing only that meeting's subdirectory afterward -- the same pattern `AtomicWriterTests` uses against `FileManager.default.temporaryDirectory`.

`schemaVersion` is a required parameter (not a fixed constant), since different cache artifacts version independently over time (mirrors `FrontmatterReader.FrontmatterV1.schemaVersion`'s per-type versioning, not a single global counter).

## Verification

**Commands:**
- `swift test --filter CacheArtifactWriter` -- expected: all `CacheArtifactWriterTests` pass.
- `scripts/check.sh lint` -- expected: 0 violations in real source files (custom `atomic_writer_bypass` rule must not fire on `CacheArtifactWriter.swift`).
- `scripts/check.sh swift` -- expected: full build + `swift test` + release build all pass (277 tests as of this writing).

## Auto Run Result

Status: blocked
Blocking condition: matrix test audit failed

Implementation is complete and correct: `Sources/Core/CacheArtifactWriter.swift` and `Tests/CoreTests/CacheArtifactWriterTests.swift` exist, `scripts/check.sh lint` and `scripts/check.sh swift` both pass (278/278 tests, release build included), and every Acceptance Criterion is met.

Five of the six I/O & Edge-Case Matrix rows have a passing covering test:
- Fresh meeting, first artifact -- `writeCreatesMeetingDirectoryWhenMissing`, `writeInjectsSchemaVersionAlongsideDialectFields`
- Rerun on same path -- `rerunOverwritesArtifactAtomically`
- Value encodes to a JSON array/scalar -- `writeThrowsNotATopLevelJSONObjectForNonObjectEncodable`
- Directory creation fails -- `writeThrowsDirectoryCreationFailedWhenPathIsBlockedByAFile`
- Underlying atomic write fails -- exercised transitively by `AtomicWriterTests` (the primitive `CacheArtifactWriter` delegates to and does not wrap)

The sixth row, "Cache root unavailable" (`.cacheRootUnavailable`, thrown when `FileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)` throws), has no covering test. On an unsandboxed macOS process this call does not fail under any condition a test can safely construct: `~/Library/Caches` is a standing OS directory, and forcing a failure would require mutating the process-wide `HOME` environment variable, which risks corrupting Swift Testing's concurrently-running tests against the real filesystem. `Sources/State/DatabasePoolFactory.swift:13-23`'s structurally identical `productionDatabasePath()` throw path has the same property and is likewise untested anywhere in this repo -- there is no existing pattern in this codebase for safely testing this class of failure.

This is an authoring gap in this spec's own I/O matrix (a row added without confirming testability), not a defect in the implementation. Two ways to resolve, for whoever picks this back up:
1. Accept the precedent `DatabasePoolFactory` already sets and drop this row from the matrix (requires editing the frozen `<intent-contract>`, which step-03 cannot do).
2. Add a subprocess-based fault-injection test (spawn a helper process with a broken `HOME`) -- new test infrastructure with no precedent here, likely disproportionate to this one row.

No code changes are needed to unblock -- only a decision on the matrix row.

**Resolution:** maintainer chose option 1 -- the "Cache root unavailable" row is dropped from the I/O & Edge-Case Matrix above. `CacheArtifactWriter.WriteError.cacheRootUnavailable` remains in the code (typed-error convention, not a force-try), it's just no longer a matrix-mandated test obligation, matching `DatabasePoolFactory.productionDatabasePath()`'s precedent. Remaining five matrix rows are all covered by passing tests; `scripts/check.sh lint` and `scripts/check.sh swift` both pass. Status: done.
