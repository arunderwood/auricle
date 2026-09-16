---
title: "Story 1.7: CLI Executable Scaffold (auricle Binary with Bare-Status + Hidden __internal-stage)"
type: 'feature'
created: '2026-09-16'
status: 'done'
baseline_revision: 'ad0f032e6aaf98597e655ebe94f07d0afe04b51f'
review_loop_iteration: 0
followup_review_recommended: true
context: ['{project-root}/_bmad-output/implementation-artifacts/epic-1-context.md']
warnings: [oversized]
deferred:
  - summary: >-
      Ordinary swift-argument-parser usage errors (missing required
      argument, unparseable flag, a missing subcommand) exit with the
      library's own usage-error code rather than Decision 1.5's "1 = user
      error."
    evidence: |-
      This is swift-argument-parser's own framework-owned automatic
      parsing-failure path, not something this story's code controls.
      Remapping it would mean re-implementing argument validation manually
      for every flag on every verb -- far beyond a trivial patch, and not
      requested anywhere in the AC, which frames the exit-code contract
      around a verb "running to completion." The framework's own usage
      message plus a nonzero exit is reasonable behavior in the meantime.
    location: >-
      All 12 App/auricle-cli/Verbs/*.swift files (framework-level, not
      story-specific code)
    severity: low
  - summary: >-
      `BareInvocation`'s tie-break order is unspecified if two meetings
      ever shared the same active state (e.g. both `recording`).
    evidence: |-
      No explicit tie-break rule exists anywhere in Decision 1.5 or this
      story's own AC. Real but low-probability: normal single-capture
      semantics mean at most one meeting is ever `recording` at a time; this
      would only surface after an unreconciled multi-meeting crash. No
      specified "correct" behavior exists yet to implement against.
    location: >-
      App/auricle-cli/Verbs/BareInvocation.swift
    severity: low
  - summary: >-
      A meeting in an active state other than the 3 `BareInvocation`
      checks (e.g. `transcribing`, `summarizing`, a `*_failed` state) falls
      through to "Nothing in flight.", which is misleading once real stages
      exist.
    evidence: |-
      Currently unreachable: no real stage implementation exists yet to put
      a meeting into these states outside test fixtures, and Decision 1.5's
      own bare-invocation table doesn't specify a message for them either.
      Whichever story wires the first real stage should revisit
      `BareInvocation` for full state coverage.
    location: >-
      App/auricle-cli/Verbs/BareInvocation.swift
    severity: low
  - summary: >-
      None of the 10 stub verbs' declared flags are asserted by an
      automated test to actually parse under their intended kebab-case
      names.
    evidence: |-
      Verified manually (by the implementation subagent and independently)
      that every flag currently parses correctly, but no regression
      protection exists — a future typo wouldn't surface until a story
      tries to read the flag. Setting up App-target argument-parsing tests
      needs new XCTest infrastructure for `App/auricle-cli` that doesn't
      exist yet; bigger than this pass's patch scope.
    location: >-
      App/auricle-cli/Verbs/*.swift
    severity: low
  - summary: >-
      `App/Project.swift`'s bundle-embedding fix (`productName`,
      `copyFiles`) has no automated regression check.
    evidence: |-
      Reverting it (the exact product-naming mismatch already found once
      during this story's planning) would silently break every real
      subprocess dispatch, with `swift test` reporting all-green since no
      CI or script in this repo runs `xcodebuild`. Closing this needs
      build-verification infrastructure that doesn't exist anywhere in this
      repo yet — explicitly Story 1.8's scope (CI enforcement layer), not
      this one's.
    location: >-
      App/Project.swift
    severity: low
  - summary: >-
      `sprint-status.yaml`'s Epic 1 entries (1-4 through 1-7) all still
      read `backlog`.
    evidence: |-
      Read `sprint-status.yaml` directly and confirmed all four entries
      still read `backlog`. Same recurring, already-documented systemic gap
      logged against every prior story this session — this workflow
      variant never touches the file; not fixable at the individual-story
      level.
    location: >-
      _bmad-output/implementation-artifacts/sprint-status.yaml
    severity: low
---

<intent-contract>

## Intent

**Problem:** `auricle-cli` (scaffolded in Story 1.1) is a bare `AsyncParsableCommand` with no subcommands, no bare-invocation status, and no way for the GUI to spawn subprocess stage workers — so every subsequent epic would need to restructure the CLI surface to add its first verb.

**Approach:** Declare all 10 MVP verbs (per Decision 1.5) as stub subcommands (print "not yet implemented", exit 2), a `BareInvocation` default subcommand backed by a real `StateStore` query (not a stub -- `StateStore` already exists and answering "what's in flight" needs nothing further), and a hidden `InternalStageWorker` subcommand validating `--worker-protocol-version` (per AR-PIPE-7). Embeds `auricle-cli` into `Auricle.app/Contents/MacOS/` per AR-DIST-3 -- this required fixing a real product-naming mismatch discovered during planning (see Design Notes) already applied to `App/Project.swift`.

## Boundaries & Constraints

**Always:**
- All 10 MVP verbs from Decision 1.5 exist as their own file under `App/auricle-cli/Verbs/<VerbName>.swift`, each declaring its **full** argument/option/flag surface (exact names/types per Decision 1.5's tables) even though the `run()` body is a stub -- the surface is what's being locked in this story, per its own Intent.
- Every stub verb's `run()` prints `"<verb> is not yet implemented."` to stderr and exits with code 2, per the AC.
- `BareInvocation` (registered as `AuricleCLI`'s `defaultSubcommand`) opens `StateStore.production()` and checks, in order: any meeting with `state == "recording"` (prints "Recording <id> — <duration>"), else `state == "awaiting_attribution"` (prints "Last meeting awaiting attribution: `auricle attribute current`"), else `state == "awaiting_verification"` (prints "Last meeting awaiting your review: `auricle keep last`"), else "Nothing in flight." -- exits 0 in every case, per Decision 1.5's bare-invocation table.
- `InternalStageWorker`'s `CommandConfiguration` sets `commandName: "__internal-stage"` and `shouldDisplay: false`; it validates `<stage>` against `PipelineStage(rawValue:)` (exit 1 if unrecognized) and `--worker-protocol-version` against the new shared `Core.WorkerProtocolVersion.current` constant (structured JSON error + exit 2 on mismatch), then -- like every other verb -- prints "not yet implemented" and exits 2, since no real stage business logic exists yet.
- `Sources/Orchestrator/SubprocessDispatcher.swift`'s two `workerProtocolVersion: Int = 1` default parameters are updated to reference `Core.WorkerProtocolVersion.current` instead of the literal `1`, so the dispatcher (sender) and `InternalStageWorker` (receiver) can never silently drift apart.
- Exit codes follow Decision 1.5 exactly: 0 success, 1 user error, 2 state error, 3 not found.
- `config` is the one grouped verb (`ConfigVerb` with nested `Get`/`Set` subcommands); every other verb is flat, per Decision 1.5's own framing.
- `App/Project.swift`'s `AuricleApp`/`auricle-cli` target changes (below) are **already made and empirically verified** by two real `xcodebuild` runs during planning -- do not re-derive or revert them.

**Never:**
- Don't implement any real verb business logic beyond the bare-invocation status query (no capture, no pipeline dispatch, no config persistence, no doctor checks) -- every other verb is a pure stub. `Config.swift` (Core) doesn't exist yet (deferred since Story 1.2); `config get`/`set` stub regardless of flags.
- Don't wire `MeetingIDResolver` (Core, already exists since Story 1.2) into any stub verb's `run()` -- every stub fails immediately regardless of whether `<id>` resolves, so resolving it first has no payoff. `<id>` is declared as a plain `@Argument var id: String` for now; real resolution is whichever future story implements each verb for real.
- Don't add a `MeetingIDDataSource` conformance to `State` -- not needed since no stub verb resolves an ID (see above).
- Don't implement v1.1-deferred verbs/flags (`pending`, `retain`, `attribute --emit-snippets/--speakers`, `doctor --fix`, `logs`, `--generate-completion-script`) -- MVP is exactly the 10 verbs.
- Don't build out the full `--json`/ANSI-color output-convention machinery (structured JSON responses, TTY-aware color) for stub verbs -- there's no real data to format yet; declaring the `--json`/`--all`/`--batch`/`--quiet` flags on the relevant verbs (the argument *surface*) is in scope, formatting real output around them is not.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Any stub verb invoked | e.g. `auricle record` | stderr: `"record is not yet implemented."` | exit code 2 |
| Bare invocation, nothing in flight | fresh/empty `StateStore` | stdout: `"Nothing in flight."` | exit code 0 |
| Bare invocation, a meeting recording | one meeting `state == "recording"` | stdout mentions that meeting's id + elapsed duration | exit code 0 |
| Bare invocation, one awaiting attribution (none recording) | one meeting `state == "awaiting_attribution"` | stdout: `"Last meeting awaiting attribution: auricle attribute current"` | exit code 0 |
| `auricle help` / `--help` / `<verb> --help` | -- | swift-argument-parser's standard help text, listing all 10 verbs (not `__internal-stage`) | exit code 0 |
| `__internal-stage` with a valid stage + matching protocol version | e.g. `__internal-stage transcribe <id> --worker-protocol-version 1` | stderr: `"__internal-stage is not yet implemented."` (falls through to the same stub pattern) | exit code 2 |
| `__internal-stage` with a mismatched protocol version | `--worker-protocol-version 99` | structured JSON error to stderr naming expected vs. received version | exit code 2 |
| `__internal-stage` with an unrecognized `<stage>` | e.g. `__internal-stage bogus <id> --worker-protocol-version 1` | user-facing error naming the bad stage | exit code 1 |
| `Auricle.app` bundle inspection | after `xcodebuild -scheme AuricleApp build` | `Contents/MacOS/` contains both `AuricleApp` and `auricle-cli`, both valid Mach-O executables | N/A |

</intent-contract>

## Code Map

- `epics.md:1050-1085` -- Story 1.7's full AC
- `architecture.md:459-618` (Decision 1.5) -- the complete CLI argument surface: 10-verb table with exact flags, ID resolution, output conventions, exit codes, error templates, JSON schema versioning -- this story's primary source, already fully read and distilled into Boundaries above
- `epics.md:257-258` (AR-PIPE-6, AR-PIPE-7) -- CLI binding contract + hidden `__internal-stage` subcommand
- `App/Project.swift` -- **already modified this planning pass** (see Design Notes): `auricle-cli` target gained `productName: "auricle-cli"` (fixes a real product-name mismatch with `Bundle.main.url(forAuxiliaryExecutable:)`); `AuricleApp` target gained a `.target(name: "auricle-cli")` dependency and a `copyFiles: [.executables(files: [.buildProduct(name: "auricle-cli", codeSignOnCopy: true)])]` action embedding it into the bundle. Verified via two real `tuist generate` + `xcodebuild` runs (`AuricleApp` and `auricle-cli` schemes each independently `BUILD SUCCEEDED`; the built `.app`'s `Contents/MacOS/` inspected directly and confirmed to contain both Mach-O binaries, correctly named).
- `App/auricle-cli/AuricleCLI.swift` -- existing minimal placeholder (Story 1.1): `@main struct AuricleCLI: AsyncParsableCommand` with `commandName: "auricle"`, no subcommands yet -- gains the full `subcommands:`/`defaultSubcommand:` list
- `Sources/Core/MeetingID.swift`, `MeetingIDResolver.swift` -- existing (Story 1.2); reused only by `BareInvocation`'s real query (via `Meeting.id`/`MeetingID(ulid:)`), not by any stub verb (see Boundaries)
- `Sources/Core/PipelineStage.swift` -- existing (Story 1.5, relocated in 1.6); reused for `InternalStageWorker`'s `<stage>` validation
- `Sources/State/StateStore.swift` -- existing `production()`/`fetchPending()`; `BareInvocation`'s real status query reads through these, no new `StateStore` method needed
- `Sources/Orchestrator/SubprocessDispatcher.swift:30,55` -- the two `workerProtocolVersion: Int = 1` literal defaults this story updates to reference the new shared constant
- `Package.swift` -- `.package(product: "ArgumentParser")` already available (declared as a `Package.swift` dependency since Story 1.1); no `Package.swift` change needed, only `App/Project.swift` (already done)

## Tasks & Acceptance

**Execution:**
- `Sources/Core/WorkerProtocolVersion.swift` -- new: `public enum WorkerProtocolVersion { public static let current = 1 }` -- single source of truth for both the dispatcher (sender) and the worker (receiver)
- `Sources/Orchestrator/SubprocessDispatcher.swift` -- change both `workerProtocolVersion: Int = 1` defaults to `= Core.WorkerProtocolVersion.current`
- `App/auricle-cli/Verbs/RecordVerb.swift` -- `record [<id>] [--replace] [--quiet]`, stub
- `App/auricle-cli/Verbs/StopVerb.swift` -- `stop [--quiet]`, stub
- `App/auricle-cli/Verbs/DiscardVerb.swift` -- `discard <id> [--quiet]`, stub
- `App/auricle-cli/Verbs/RunVerb.swift` -- `run <id> [--force] [--from <stage>] [--to <stage>] [--only <stage>] [--reattribute] [--publish-anyway]`, stub
- `App/auricle-cli/Verbs/AttributeVerb.swift` -- `attribute <id> [--batch]`, stub
- `App/auricle-cli/Verbs/KeepVerb.swift` -- `keep <id> [--quiet]`, stub
- `App/auricle-cli/Verbs/ListVerb.swift` -- `list [--all] [--json]`, stub
- `App/auricle-cli/Verbs/StatusVerb.swift` -- `status <id> [--json]`, stub
- `App/auricle-cli/Verbs/ConfigVerb.swift` -- `config` parent (`CommandConfiguration(subcommands: [Get.self, Set.self])`); `Get.self` = `config get [<key>]`, stub; `Set.self` = `config set <key> <value>`, stub
- `App/auricle-cli/Verbs/DoctorVerb.swift` -- `doctor`, stub
- `App/auricle-cli/Verbs/BareInvocation.swift` -- real: opens `StateStore.production()`, checks `recording` → `awaiting_attribution` → `awaiting_verification` in order per Boundaries, prints the matching message or "Nothing in flight.", exits 0
- `App/auricle-cli/Verbs/InternalStageWorker.swift` -- `CommandConfiguration(commandName: "__internal-stage", shouldDisplay: false)`; `<stage> <id> --worker-protocol-version <Int>`; validates stage against `PipelineStage(rawValue:)` (exit 1 if bad) and version against `Core.WorkerProtocolVersion.current` (structured JSON error + exit 2 if mismatched); otherwise stub
- `App/auricle-cli/NotYetImplemented.swift` -- small shared helper (e.g. `func notYetImplemented(_ verbName: String) throws -> Never`) printing to stderr and throwing `ExitCode(2)`, used by all stub verbs to avoid repeating the same three lines eleven times
- `App/auricle-cli/AuricleCLI.swift` -- `CommandConfiguration(commandName: "auricle", abstract: ..., subcommands: [RecordVerb.self, StopVerb.self, DiscardVerb.self, RunVerb.self, AttributeVerb.self, KeepVerb.self, ListVerb.self, StatusVerb.self, ConfigVerb.self, DoctorVerb.self, InternalStageWorker.self], defaultSubcommand: BareInvocation.self)`

**Acceptance Criteria:**
- Given `tuist generate --no-open && xcodebuild -project App/Auricle.xcodeproj -scheme auricle-cli build`, when it completes, then it exits 0 with no new warnings attributable to this story's files
- Given the built `auricle-cli` binary run directly with no arguments against a fresh/empty database, when it executes, then it prints "Nothing in flight." and exits 0
- Given `xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp build`, when it completes, then `Contents/MacOS/` of the produced `.app` contains both `AuricleApp` and `auricle-cli` as valid executables (regression check on the already-applied `Project.swift` change)
- Given `swift build && swift test`, when run, then all existing SwiftPM library tests still pass (regression check on the `SubprocessDispatcher`/`Core` changes)

## Spec Change Log

## Review Triage Log

### 2026-09-16 — Review pass
- verdicts: 22 findings — high 0, medium 4, low 18, false 0, maybe-false 0
- findings:
  - `[low]` `[patch]` `BareInvocation.run()` calls `StateStore.production()`/`fetchPending()` with no local error handling -- a throw escapes to swift-argument-parser's generic handler, bypassing Decision 1.5's 0/1/2/3 exit-code contract every stub verb otherwise honors (Blind Hunter) -- Verified: read `run()`, confirmed no `do`/`catch`. Action: wrapped the body in `do`/`catch`, writing a stderr message and throwing `ExitCode(2)` (state error) on failure.
  - `[low]` `[patch]` Same gap independently confirmed with a proposed fix (Edge Case Hunter) -- grouped with the row above, same fix.
  - `[medium]` `[patch]` `BareInvocation`'s state-priority branching (recording → awaiting_attribution → awaiting_verification → nothing) and its `elapsed(since:)`/`parseISO8601` duration formatting have zero automated test coverage -- `App/auricle-cli` is a Tuist target with no SwiftPM test target, so `swift test` structurally cannot reach this code (Blind Hunter) -- Verified: grepped the repo, confirmed no test references `BareInvocation`. Action: extracted the priority-branch decision and duration formatting into a plain, testable function in `Sources/Core` (SwiftPM-visible), with unit tests covering each of the 4 branches and both ISO8601 formats; `BareInvocation.run()` is now a thin wrapper calling it.
  - `[medium]` `[patch]` Same gap independently confirmed, pre-verified with a specific fix proposal (Verification Gap Reviewer) -- grouped with the row above, same fix.
  - `[medium]` `[patch]` Same gap also raised, framed as a structural consequence of `App/auricle-cli` living outside `Package.swift`'s test-reachable targets (Intent Alignment Auditor) -- grouped with the row above, same fix; also explains *why* this story (unlike 1.4-1.6) shipped no new automated tests.
  - `[medium]` `[patch]` `InternalStageWorker`'s stage/protocol-version validation and its JSON error shape are likewise never exercised by any test -- `SubprocessDispatcherTests`/`CrashRecoveryTests` both replace the real executable with a stub that ignores all arguments (Verification Gap Reviewer, pre-verified) -- Action: extracted the stage-validity check, version comparison, and JSON-shape construction into a plain, testable function/type in a SwiftPM module, with unit tests for a valid stage+version, an invalid stage (exit-1 path), and a mismatched version (asserting the exact JSON field names).
  - `[low]` `[patch]` `InternalStageWorker`'s protocol-mismatch path uses `try?` twice with no `else` branch -- if JSON encoding fails, it silently exits 2 with **zero** stderr output, contradicting the AC's "structured JSON error to stderr naming expected vs. received version" (Blind Hunter) -- Verified: read the `if let json = ..., let jsonString = ... { writeStderr(...) }` with no fallback. Action: added an `else` branch printing a plain-text fallback message (still naming expected/received) so a caller always gets *something* on stderr even if JSON encoding somehow fails.
  - `[low]` `[patch]` Same gap independently confirmed (Edge Case Hunter) -- grouped with the row above, same fix.
  - `[low]` `[defer]` Ordinary swift-argument-parser usage errors (missing required `<id>`, unparseable flag, `config` with no subcommand) exit with the library's own usage-error code (64/`EX_USAGE`), not Decision 1.5's "1 = user error" -- nothing in the diff remaps ArgumentParser's own automatic parsing-failure path (Blind Hunter) -- Verified: this is swift-argument-parser's standard, framework-owned behavior for every command built on it; remapping it would mean re-implementing argument validation manually for every flag on every verb, well beyond a trivial patch, and isn't asked for anywhere in the AC (which frames the exit-code contract around a verb "running to completion," not upstream parsing). Settled by: revisit if a future story finds this UX gap actually matters to a user (the framework's own usage message + nonzero exit is still reasonable behavior in the meantime).
  - `[low]` `[defer]` Same gap for the specific case of a missing `--worker-protocol-version` on `__internal-stage` (Edge Case Hunter) -- grouped with the row above, same disposition.
  - `[low]` `[defer]` Same gap for the specific case of `auricle config` invoked with no `get`/`set` subcommand (Edge Case Hunter) -- grouped with the row above, same disposition.
  - `[low]` `[reject]` The spec's own "Tasks & Acceptance" section text for `AuricleCLI.swift`'s `subcommands:` list omits `BareInvocation.self`, but the actual shipped code (correctly) includes it (Blind Hunter) -- Real spec-text inaccuracy, but its only fix is editing this build's spec, which is categorically rejected per the classify rules regardless of merit. The code itself is correct and was independently verified (bare invocation works; `--help` lists exactly the 10 real verbs).
  - `[low]` `[reject]` Same mismatch independently confirmed, pre-verified with high confidence (Edge Case Hunter) -- grouped with the row above, same disposition.
  - `[low]` `[reject]` The spec's Code Map claims `BareInvocation` reuses `MeetingID`/`MeetingIDResolver`, but the shipped code never imports `Core` for this purpose -- it interpolates `recording.id` directly, which is simpler and equally correct (Blind Hunter) -- Same disposition: fix is to edit the spec, categorically rejected. No functional gap: the AC only requires the meeting's id to appear in the message, which it does.
  - `[low]` `[reject]` The spec's Acceptance Criteria build command for `auricle-cli` omits `-destination "platform=macOS"` while the near-identical command in the Verification section includes it (Blind Hunter) -- Same disposition: fix is to edit the spec. Both real build/verification runs performed during this pass used the correct, fully-qualified command; no ambiguity was actually hit.
  - `[low]` `[defer]` `BareInvocation`'s `pending.first(where:)`/`.contains` checks depend on `StateStore.fetchPending()`'s return order; if two meetings ever shared the same active state (e.g. after an unreconciled crash), which one gets reported is unspecified (Blind Hunter) -- Verified: confirmed no explicit tie-break rule exists anywhere in Decision 1.5 or this story's own AC. Real but low-probability (normal single-capture semantics mean at most one meeting is ever `recording`) and no specified "correct" behavior exists to implement. Settled by: whichever future story handles multi-meeting crash reconciliation for real.
  - `[low]` `[defer]` A meeting in an active state other than the 3 checked (e.g. `transcribing`, `summarizing`, a `*_failed` state) currently falls through to `"Nothing in flight."`, which is misleading -- something *is* in flight (Edge Case Hunter) -- Verified: read the branch chain, confirmed no fallback for other active states. Real, but currently unreachable -- no real stage implementation exists yet to ever put a meeting into these states outside test fixtures, and Decision 1.5's own bare-invocation table doesn't specify a message for them either. Settled by: whichever story wires the first real stage revisits `BareInvocation` to add full state coverage (or a generic "Meeting `<id>` is `<state>`." fallback).
  - `[low]` `[defer]` None of the 10 stub verbs' declared flags (`--quiet`, `--json`, `--all`, `--batch`, etc.) are asserted by an automated test to actually parse under their intended kebab-case names -- a typo wouldn't surface until a future story tries to read the flag (Blind Hunter) -- Verified manually (both by the implementation subagent and independently) that every flag currently parses correctly, but no regression protection exists. Setting up App-target argument-parsing tests is a real infrastructure investment (no XCTest target for `App/auricle-cli` exists), bigger than this pass's patch scope. Settled by: whichever story first needs to add App-side test infrastructure for real verb logic.
  - `[low]` `[patch]` `NotYetImplemented.swift`'s `writeStderr` uses the non-throwing `FileHandle.write(_:)`, which raises an uncaught Objective-C exception if the write fails (e.g. a closed/broken stderr pipe) -- a crash instead of a clean exit (Edge Case Hunter) -- Verified: read the implementation, confirmed the older non-throwing API is used. Action: switched to the modern throwing `write(contentsOf:)` wrapped in `try?` -- a best-effort write is strictly more robust than a potential crash, and this is used purely for diagnostic output where a failed write has nothing further to report.
  - `[low]` `[defer]` `App/Project.swift`'s bundle-embedding fix (`productName`, `copyFiles`) has no automated regression check -- reverting it (the exact mismatch already found once during planning) would silently break every real subprocess dispatch with `swift test` reporting all-green, since no CI or build script in this repo runs `xcodebuild` (Verification Gap Reviewer) -- Agreed with the reviewer's own disposition: closing this needs build-verification infrastructure (CI running `xcodebuild`, or a bundle-inspection script) that doesn't exist anywhere in this repo yet -- that's explicitly Story 1.8's scope (CI enforcement layer), not this one's.
  - `[low]` `[defer]` `sprint-status.yaml`'s Epic 1 entries (now 1-4 through 1-7) all still read `backlog` (Intent Alignment Auditor) -- Verified: read `sprint-status.yaml` directly. Same recurring, already-documented systemic gap logged against every prior story this session -- not fixable at the individual-story level.

## Design Notes

**The product-naming mismatch this story's planning found and already fixed:** Tuist derives a target's built executable filename from its `name` unless `productName` overrides it, and Swift target/module names can't contain hyphens -- so `auricle-cli` (the Tuist target name, matching architecture.md's own naming throughout) was actually building an executable literally named `auricle_cli` (underscore). `SubprocessDispatcher` (Story 1.5) and AR-PIPE-7 both invoke `Bundle.main.url(forAuxiliaryExecutable: "auricle-cli")` (hyphen) -- a name that would never have been found at runtime. Verified via a real build before this story's spec was written (the DerivedData product was literally named `auricle_cli`); fixed by adding `productName: "auricle-cli"` to the Tuist target declaration, then re-verified the corrected name appears in a rebuilt `.app` bundle.

**Why the `copyFiles` embedding uses `.buildProduct(name:)` rather than a `$(BUILT_PRODUCTS_DIR)`-based path string:** the first attempt (a literal build-setting path string) failed at `tuist generate` time with "No files found at: .../$(BUILT_PRODUCTS_DIR)/auricle-cli" -- Tuist resolves `CopyFileElement` globs against the filesystem at *generation* time, not at Xcode build time, so a raw build-setting string can never resolve. `CopyFileElement.buildProduct(name:)` is Tuist's dedicated case for referencing a sibling target's product by name, resolved through the project graph rather than the filesystem -- confirmed by inspecting the installed Tuist version's own compiled `ProjectDescription.swiftinterface` rather than guessing, then re-verified by a full rebuild showing both binaries correctly landing in `Contents/MacOS/`.

**Why `BareInvocation` gets a real implementation while every other verb is a stub:** every other MVP verb needs business logic that doesn't exist yet (capture, pipeline dispatch, config persistence, permission/doctor checks). Bare-invocation status needs only what Story 1.4's `StateStore` already provides (`production()`, `fetchPending()`) -- there's no missing primitive to stub around, and the AC itself frames the stub fallback as conditional ("if upstream stages aren't wired"), which isn't the case here.

## Verification

**Commands:**
- `tuist generate --no-open` (run from `App/`) -- expected: `✔ Success` (regenerates `Auricle.xcodeproj` from the already-modified `Project.swift`)
- `xcodebuild -project App/Auricle.xcodeproj -scheme auricle-cli -destination "platform=macOS" build` -- expected: `** BUILD SUCCEEDED **`
- `xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp -destination "platform=macOS" build` -- expected: `** BUILD SUCCEEDED **`; then inspect the built `.app`'s `Contents/MacOS/` directly (`find`/`file`) to confirm both `AuricleApp` and `auricle-cli` are present as Mach-O executables
- Run the built `auricle-cli` binary directly with no arguments (against a temp/fresh production path, or by pointing `StateStore` at a scratch DB) -- expected: `"Nothing in flight."`, exit 0; and with each stub verb (e.g. `record`, `list`) -- expected: `"<verb> is not yet implemented."` on stderr, exit 2
- `swift build && swift test` -- expected: exit 0, all existing tests still pass (regression on `Core`/`Orchestrator` changes)

## Auto Run Result

**Summary:** Declared all 10 MVP verbs (Decision 1.5) as stub subcommands under `App/auricle-cli/Verbs/`, each with its full argument surface but a "not yet implemented" `run()` body. `BareInvocation` (the default subcommand) does real work, backed by `StateStore`. `InternalStageWorker` validates `<stage>`/`--worker-protocol-version` before falling through to the same stub pattern. Fixed a real product-naming mismatch in `App/Project.swift` (Tuist was building `auricle_cli`, not `auricle-cli`, which `Bundle.main.url(forAuxiliaryExecutable:)` would never have found) and embedded the CLI binary into `Auricle.app/Contents/MacOS/` per AR-DIST-3 — both empirically verified via real `tuist generate`/`xcodebuild` runs, not just declared.

**Files changed:**
- `App/Project.swift` -- `productName: "auricle-cli"` fix; `copyFiles`/target-dependency embedding the CLI into the GUI's `.app` bundle
- `App/auricle-cli/AuricleCLI.swift` -- wired `subcommands:`/`defaultSubcommand:`
- `App/auricle-cli/NotYetImplemented.swift` -- shared stub-exit helper
- `App/auricle-cli/Verbs/{Record,Stop,Discard,Run,Attribute,Keep,List,Status,Config,Doctor}Verb.swift` -- the 10 MVP stubs
- `App/auricle-cli/Verbs/BareInvocation.swift` -- real status query, now a thin wrapper over `Core.BareInvocationResolver`
- `App/auricle-cli/Verbs/InternalStageWorker.swift` -- hidden subcommand, now a thin wrapper over `Core.InternalStageValidator`
- `Sources/Core/{BareInvocationStatus,InternalStageValidation,WorkerProtocolVersion,ISO8601UTC}.swift` -- extracted, testable logic (`ISO8601UTC` relocated here from `Orchestrator` to eliminate a duplicate implementation)
- `Sources/Orchestrator/SubprocessDispatcher.swift` -- references the shared `WorkerProtocolVersion.current` instead of a literal `1`
- `Tests/CoreTests/{BareInvocationResolverTests,InternalStageValidatorTests}.swift` -- new unit coverage for the extracted logic
- 114 tests pass repo-wide; both `auricle-cli` and `AuricleApp` Xcode schemes build clean

**Review findings breakdown** (22 findings across Blind Hunter, Edge Case Hunter, Verification Gap Reviewer, Intent Alignment Auditor — full detail in `## Review Triage Log` above):
- **Patched (9 findings: 4 medium, 5 low):** two structural testability gaps -- `BareInvocation`'s status logic and `InternalStageWorker`'s validation logic both had zero automated coverage since `App/auricle-cli` sits outside `swift test`'s reach; both extracted into tested `Core` code. Also: unguarded `StateStore` errors in `BareInvocation` bypassing the app's exit-code contract; a silent JSON-encode-failure path in the version-mismatch error; a crash-prone non-throwing `FileHandle.write` call.
- **Deferred (6 findings, all low):** swift-argument-parser's own usage-error exit codes not remapped to Decision 1.5's contract (framework-owned behavior, not a trivial fix); an unspecified tie-break if two meetings ever shared the same active state; other active states (transcribing, etc.) falling through to "Nothing in flight." (currently unreachable -- no real stage exists yet); stub verb flags not covered by automated parsing tests (needs new App-side test infrastructure); the bundle-embedding fix having no CI regression check (explicitly Story 1.8's scope); the continuing `sprint-status.yaml` staleness.
- **Rejected (3 findings, all low):** three spec-text inaccuracies (a stale code snippet, an overclaimed reuse, an inconsistent build command) whose only "fix" would be editing this build's spec -- categorically rejected per the classify rules; the actual shipped code was independently verified correct in every case.

**Follow-up review recommendation:** `true` -- two `medium` findings were patched this pass (both testability extractions). Specific unverified risk: the extracted `BareInvocationResolver`/`InternalStageValidator` logic is now well-tested in isolation, but neither has a caller yet beyond these two thin verb wrappers -- worth confirming once a real composition root exists that nothing about the extraction changed observable CLI behavior in a way these new unit tests wouldn't catch (the manual binary spot-checks performed this pass are the closest thing to that confirmation today).

**Verification performed:** `swift build` (clean) and full `swift test` (114/114 pass) re-run independently after the patch batch. `tuist generate --no-open` followed by `xcodebuild` for both the `auricle-cli` and `AuricleApp` schemes (both `BUILD SUCCEEDED`), re-verified independently rather than trusted from the implementer's report. Directly read `BareInvocationStatus.swift`, `InternalStageValidation.swift`, and the now-thin `BareInvocation.swift`/`InternalStageWorker.swift` wrappers to confirm the extraction preserved behavior rather than just trusting green tests. I/O & Edge-Case Matrix audit: all 9 rows verified via direct binary execution both before and after the patch batch (this story has no `@Test`-based matrix coverage by its own design -- see the deferred App-side-test-infrastructure finding -- so manual/direct verification is this story's actual verification mechanism, matching its own Verification section).

**Residual risks:** `App/Project.swift`'s bundle-embedding fix and every CLI behavior in this story have no CI regression protection yet (no CI configuration exists anywhere in this repo) -- a future accidental revert would ship silently until Story 1.8 (lint/CI enforcement layer) closes that gap. `sprint-status.yaml` continues to understate progress across all four stories delivered this session.
