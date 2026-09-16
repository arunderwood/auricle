---
title: 'Story 1.3: Log Facade with Sensitivity Tagging and Redaction'
type: 'feature'
created: '2026-09-16'
status: 'done'
baseline_commit: '84e917e4ae6edebc0c45493165798bae874873a8'
route: 'dispatch'
review_loop_iteration: 0
context: ['{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** `Core` has no logging primitive. Every future stage/module needs one sanctioned way to write structured logs to the unified logging system without ever leaking secrets, transcript content, or API response bodies (FR61, NFR-S7, AR-PAT-3).

**Approach:** Implement `Log` in `Sources/Core/Log.swift`, wrapping `os.Logger`, subsystem locked to `com.auricle.app`, category per call site. Every field passed to a log call is required — by the type system — to be tagged `.publicSafe` or `.sensitive` via a `LogSensitivity` enum. The facade redacts `.sensitive` values itself before the message reaches `Logger`, so `log show` visibility (NFR-M3) doesn't depend on OSLog's own privacy classifiers.

## Boundaries & Constraints

**Always:**
- Subsystem is always the literal `"com.auricle.app"` — not a parameter.
- Every field passed to `.info`/`.warn`/`.error`/`.debug` is a `LogSensitivity` (`.publicSafe`/`.sensitive`) — no untagged raw values accepted by the API shape itself.
- `.sensitive` values are redacted (replaced by a fixed marker) before the message string is built, so the result is always safe to mark `.public` when handed to `Logger` — `log show` stays a usable operational surface without depending on OSLog's per-interpolation privacy, which only works for literal compile-time interpolation at each call site, not inside a shared wrapper.
- `debug` calls compile to nothing in release builds (`#if DEBUG`).

**Never:**
- Don't add a lint/CI rule that detects direct `os_log`/`print` bypass — that's Story 1.8; this story's enforcement is the type signature itself.
- Don't pass Anthropic response bodies, API keys, OAuth tokens, transcript content, or attendee emails to `Log` in any form, tagged or not — scrubbing at the call site is a code-review concern here, not this facade's job.
- Don't touch `Sources/Telemetry/` — Story 1.6 owns `StageEventLogger`/`Telemetry.record`; this story is the plain logging facade only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Mixed fields | message + one `.publicSafe` + one `.sensitive` field | Built string contains the public value verbatim and a fixed redaction marker in place of the sensitive one | N/A |
| API-response-shaped fixture | `.sensitive(rawResponseBody)` | Redaction marker only; raw body never appears in the built string | N/A |
| `debug` outside a DEBUG build | `log.debug(...)` under a non-DEBUG compilation config | Call site is a no-op; no formatting work performed | N/A |
| No fields | message only | Message logged as-is | N/A |

</frozen-after-approval>

## Code Map

- `Sources/Core/Log.swift` -- new; doesn't exist yet (`grep -rn "os_log\|OSLog\|Logger(" Sources/` returns nothing)
- `Sources/Core/Errors.swift:1-50` -- sibling-primitive pattern (public enum, one file, associated values) for reference only; no new error case needed — logging never throws
- `Package.swift:53` -- `Core` target already declared; no dependency change (uses only `Foundation`/`os`, both system frameworks)
- `epics.md:892-926` -- authoritative ACs; `epics.md:308` -- AR-PAT-3 (locked subsystem, category vocabulary, tagging rule)
- `architecture.md:1252-1263` -- `LogSensitivity` sketch and privacy-routing rationale; `architecture.md:2028-2039` -- level semantics (`debug`/`info`/`warn`/`error`)
- `Tests/CoreTests/AtomicWriterTests.swift`, `ULIDTests.swift` -- existing per-primitive test-file precedent to mirror

## Tasks & Acceptance

**Execution:**
- [x] `Sources/Core/Log.swift` -- `LogSensitivity` enum (`.publicSafe`/`.sensitive`, statics accepting `CustomStringConvertible`) + `Log` struct wrapping `os.Logger` (subsystem locked, `category: String` init param, `.debug`/`.info`/`.warn`/`.error(_ message: String, _ fields: [String: LogSensitivity] = [:])`, an internal pure message-building function for testability) -- FR61, NFR-S7, NFR-M3, AR-PAT-3
- [x] `Tests/CoreTests/LogTests.swift` -- category/subsystem plumbing, no-fields case, publicSafe-value-appears-verbatim case
- [x] `Tests/CoreTests/LogRedactionTests.swift` -- both redaction I/O Matrix rows, including the API-response-shaped fixture -- AC4

**Acceptance Criteria:**
- [x] Given a message with one `.publicSafe` and one `.sensitive` field, when the message is built, then the sensitive value is absent from the output and a redaction marker stands in its place -- verified: `LogRedactionTests.mixedFieldsRedactSensitiveAndKeepPublicSafeVerbatim`
- [x] Given `Sources/Core/`, when `swift build && swift test --filter CoreTests` runs, then both succeed with zero warnings and all new tests pass -- verified independently: build exit 0, no Core warnings, 25/25 tests pass (19 pre-existing + 6 new)

## Implementation Notes

- `LogSensitivity.publicSafe`/`.sensitive` are declared as `case _(String)` plus an overloaded `static func` of the same name taking `some CustomStringConvertible`. Swift resolves a literal `String` argument to the case constructor directly and any other `CustomStringConvertible` (e.g. an `Int` duration, a `MeetingID`) to the generic static, with no ambiguity — confirmed with a standalone compile check before committing to the pattern.
- Redaction happens once, in `Log.buildMessage`, before any `Logger` call — not via OSLog's `%{public}@`/`%{private}@` privacy formatters. Those formatters only take effect on a literal, compile-time string interpolation written at the call site; a shared wrapper interpolating a value built from a runtime `[String: LogSensitivity]` dictionary can't rely on them (this is the frozen Intent's stated rationale, not a new decision). Every `Logger` call therefore passes the already-redacted string with explicit `privacy: .public`.
- `warn` calls `logger.notice(...)`, not `logger.warning(...)` — confirmed `Logger.warning` exists on this toolchain (Swift 6.3.1) but the Design Notes' explicit level mapping (`warn` → `.default`/"notice", one step below `.error`) is what's implemented, per the spec's own stated rationale rather than the newer convenience API.
- `buildMessage` sorts fields by key before joining: `[String: LogSensitivity]` iteration order is not deterministic, and a non-deterministic message would make both the redaction tests and any future golden-output test flaky.
- `category` and `Log.subsystem` are internal (not `public`) stored properties, present solely so `LogTests.categoryIsPlumbedFromInitAndSubsystemIsLocked` can assert the locked-subsystem/per-call-site-category plumbing without needing to introspect a constructed `os.Logger`, which exposes no such accessor.
- Verified with `swift build` (full package, exit 0) and `swift test --filter CoreTests` (25/25 pass: 19 pre-existing + 6 new). `swift build --target Core` in isolation shows zero warnings attributable to `Core` (the only warnings anywhere in the build are pre-existing, from other stories' not-yet-created test-target directories declared in `Package.swift`, unrelated to this diff). `grep -rn "os_log\|OSLog\|Logger(" Sources/` matches only inside `Sources/Core/Log.swift`.
- Independently re-verified during orchestrator review: the I/O Matrix's "`debug` outside a DEBUG build" row has no dedicated `XCTest`/swift-testing case (compile-time stripping isn't runtime-observable in one test binary). Confirmed instead by `swift build -c release --target Core` succeeding cleanly (exit 0, zero warnings) plus direct inspection of `Log.swift`: `debug`'s entire body, including the call to `buildMessage`, sits inside `#if DEBUG ... #endif`, so SwiftPM's release configuration (which does not define `DEBUG`) omits it from compilation entirely rather than emitting dead code.

## Spec Change Log

## Review Triage Log

| # | Finding | Verdict | Route | Evidence |
|---|---------|---------|-------|----------|
| 1 | `Log.buildMessage`'s `"key=value"` join has no escaping — a `.publicSafe` value containing `=`, a space, or a newline fragments the format (Blind Hunter + Edge Case Hunter) | low | reject | Verified: `buildMessage` joins `"\(key)=\(stringValue)"` with no escaping. Real but narrow — architecture.md's `.publicSafe` category (bundle id, stage name, meeting id, durations, exit codes) excludes free text/paths, so no documented call site can trigger it; the fix (an escaping scheme) is more than a direct correction. |
| 2 | `LogSensitivity`'s doc comment claims "the API shape itself has no untagged path," but that only covers the `fields` dictionary — the free-text `message: String` parameter is unconstrained (Blind Hunter) | low | patch | Verified: `message` accepts any `String`; nothing stops embedding raw sensitive text there. The Boundaries section already scopes this correctly ("scrubbing at the call site is a code-review concern") — only the doc comment overclaims. |
| 3 | `buildMessage`'s `.sorted { $0.key < $1.key }` (added for deterministic output) is asserted by no test — every redaction test uses `.contains(...)` substring checks that pass regardless of field order (Blind Hunter + Verification Gap) | low | patch | Verified: grepped `LogTests.swift`/`LogRedactionTests.swift` — no test asserts an exact composed string with 2+ fields, so removing `.sorted` would not fail any current test. |
| 4 | Implementation drops OSLog's `%{public}@`/`%{private}@` privacy modifiers entirely in favor of message-construction redaction, deviating from architecture.md's primary/backstop design, with no Spec Change Log entry (Blind Hunter) | false | reject | Verified: this rationale is already recorded in the frozen `## Intent` and `## Boundaries & Constraints` sections — not the Spec Change Log, which is reserved for step-04 review-loop amendments, not original planning-time design. architecture.md's "backstop" language describes a hypothetical future file-output path, not the `os.Logger` path used here; OSLog's per-interpolation privacy needs a literal call-site interpolation a shared wrapper structurally cannot provide, so no real backstop was ever available to lose. |
| 5 | `warn` maps to `logger.notice(...)` rather than the newer `logger.warning(...)` API; no test distinguishes the two since neither crashes, and it's unconfirmed whether they differ in `log show`/Console filtering visibility (Blind Hunter) | medium (if true, unverified) | defer | The choice is deliberate and documented (Design Notes), but whether `.notice` vs `.warning` actually differ in operational visibility — which matters given NFR-M3's "canonical operational surface" goal — isn't confirmed against current OSLog behavior. Settled by: checking Apple's current `Logger` docs/behavior for a `.warning` vs `.notice` filtering difference. |
| 6 | `.publicSafe`/`.sensitive` static-vs-case overload resolution was "confirmed with a standalone compile check" but every test call site uses a literal, never a `String`-typed variable — the case Blind Hunter felt most likely to expose ambiguity (Blind Hunter) | false | reject | Verified: Swift overload resolution is based on an expression's static type, not whether it's syntactically a literal; a `String`-typed variable and a string literal both have static type `String` and resolve identically. No distinct ambiguity risk exists. |
| 7 | `buildMessage` with an empty `message` and non-empty `fields` produces a leading space (`" field=value"`) — untested edge case (Blind Hunter + Edge Case Hunter) | low | patch | Verified: `"\(message) \(rendered)"` with `message == ""` yields a leading space. No real call site passes an empty message today, but the fix is a direct one-line correction. |
| 8 | The four level methods (`debug`/`info`/`warn`/`error`) repeat the identical `logger.X("\(Log.buildMessage(...), privacy: .public)")` shape, duplicating the "always redact before `.public`" invariant four times instead of enforcing it once (Blind Hunter) | low | patch | Verified: each method independently calls `buildMessage` then marks `.public`; a future edit to one method's redaction step wouldn't automatically apply to the other three. Extracting a shared private helper removes the duplication with no public-surface change. |
| 9 | No test exercises the public `log.debug/.info/.warn/.error` entry points with a `.sensitive` field — only `Log.buildMessage` is tested directly, so a future edit that stopped routing those methods through `buildMessage` would ship undetected (Verification Gap) | medium (if true, unverified) | defer | Filed pre-verified by the verification-gap layer: confirmed via `swift test --filter CoreTests` (25/25 pass) and grep that only `LogTests.swift`/`LogRedactionTests.swift` call `Log`/`buildMessage`, none passing `.sensitive` through the public methods. Closing this needs an injectable `Logger` sink — a larger redesign than this facade story scopes. Settled by: that redesign, likely alongside Story 1.6/1.8. |
| 10 | The I/O Matrix's "`debug` outside a DEBUG build" row was verified once manually (`swift build -c release`) with no repeatable automated check — nothing in this repo re-runs that command (Verification Gap) | medium (if true, unverified) | defer | Filed pre-verified: confirmed no CI, `Makefile`, or scripts exist yet to wire this in. Story 1.8 (lint/CI enforcement) is the explicitly scoped owner of this kind of check. Settled by: Story 1.8 adding a release-config build step to CI. |

## Design Notes

epics.md's and architecture.md's call-site pseudocode (`log.info("...", duration: .publicSafe(x), audioPath: .sensitive(y))`) uses Swift keyword-argument syntax, which can't generalize to arbitrary field names in a real method signature. This story's `[String: LogSensitivity]` dictionary parameter is the concrete realization of the same tagging discipline: `log.info("transcribe completed", ["duration": .publicSafe(durationMs), "audioPath": .sensitive(path)])`.

`warn` has no direct `OSLogType` equivalent; maps to `.default` (OSLog's "notice" level — persisted and visible in `log show` without special flags, one step below `.error`).

## Verification

**Commands:**
- `swift build && swift test --filter CoreTests` -- expected: exit 0, all tests pass, zero Core warnings
- `swift build -c release --target Core` -- expected: exit 0, zero warnings (confirms the `#if DEBUG`-gated `debug(...)` body compiles cleanly out of release)
- `grep -rn "os_log\|OSLog(" Sources/Core/Log.swift` -- expected: matches only inside `Log.swift` (confirms nothing else in this diff bypasses the facade)
