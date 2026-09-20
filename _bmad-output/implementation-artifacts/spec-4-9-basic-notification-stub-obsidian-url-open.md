---
title: 'Story 4.9: Basic Notification Stub + Obsidian URL Open'
type: 'feature'
created: '2026-09-20'
status: 'done'
baseline_revision: '6c5d61ad86c4647c811d73dcc5c501599cd972bc'
review_loop_iteration: 0
followup_review_recommended: false
context: [
  '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md',
]
warnings: [oversized]
deferred:
  - summary: >-
      The GUI notifier can hang on a permission prompt at fire time, and no delegate is installed when the vault or state store is unavailable.
    evidence: |-
      SystemNotificationCenter.isAuthorized() requests authorization on notDetermined; AuricleApp.makeNotificationDelegate returns nil without a vault path or store. Unverified in a running app; settle when the GUI dispatches in Epic 6.
    location: >-
      App/Auricle/NotificationDelegate.swift
    severity: medium (unverified)
  - summary: >-
      The notify stage records no NotifyMeta (notification_id, delivered) in stage_events.
    evidence: |-
      architecture.md documents the shape; Notifier.fire returns nothing, so delivery is unknown. Story 8.1's full Notifier owns it.
    location: >-
      Sources/Notifications/NotifyStage.swift
    severity: low
---

<intent-contract>

## Intent

**Problem:** Nothing owns the `published → awaiting_verification` transition, and a published note gives the maintainer no pointer to it. Epic 4's CLI dogfood needs the note path and its Obsidian URL on the terminal.

**Approach:** Declare a `Notifier` protocol in `Sources/Notifications` with two conformers: `StdoutNotifier` (CLI) and `UserNotificationNotifier` (GUI). Add a `NotifyStage` that fires the notifier, tolerates its failure, and moves the meeting to `awaiting_verification`. Add a click handler that opens the note in Obsidian. The acceptance criteria in `epics.md` Story 4.9 are the full contract.

## Boundaries & Constraints

**Always:** Logic lives in `Sources/Notifications`; `App/` files are thin wrappers. `Notifier.fire(meetingID:, title:, vaultPath:) async` does not throw. `vaultPath` is the absolute note path from `meetings.vault_note_path`; each conformer also takes the vault root at init, to derive the `vault=` name. The URL is `obsidian://open?vault=<name>&file=<vault-relative path without .md>`, percent-encoded. The payload is `{meeting_id, schema_version: 1, payload_version: 1}`, snake_case, explicit `CodingKeys`. State writes go through `StageRunner`, never directly. All logging uses `Log`.

**Never:** No system notification from the CLI. No `Verifier.markVerified` call and no retention-timer arming on click (Epic 8). No `print(` (lint rule): `StdoutNotifier` writes through an injectable sink whose default is `FileHandle.standardOutput`. No wiring into `RunVerb` (Story 4.7 owns it, and it is still a stub).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| CLI fire | note `<vault>/Meetings/a b.md` | Two stdout lines: the note path, then the `obsidian://` URL with `%20` for spaces | None |
| GUI fire, fresh | title `Tuesday sync with Ben` | Request body `auricle: meeting ready — Tuesday sync with Ben`, `userInfo` as above | Permission denied: `Log.warn`, return |
| GUI fire, re-publish | note `x--rerun-2026-05-15.md` (or `-2` ordinal) | Body `auricle: re-published <title> (rerun 2026-05-15)` | Same |
| Fresh fallback | note has no `--rerun-` suffix | Standard `meeting ready` body | None |
| Notify stage | meeting `published`, notifier fails or is a no-op | Meeting reaches `awaiting_verification`; stage event recorded | Notifier cannot throw |
| Click, known payload | `meeting_id` with `vault_note_path` set | Opener called once with the URL | Opener failure logged, ignored |
| Click, unknown `payload_version` or no note path | future payload, or no row/path | Opener not called; `Log.warn` | Never throws |

</intent-contract>

## Code Map

- `Sources/Notifications/ManifestPlaceholder.swift` -- delete once real files land.
- `Package.swift` (`Notifications` target line ~99, `NotificationsTests` ~217) -- add `Orchestrator`, `Telemetry` to the target; tests add `Core`, `State`, `Orchestrator`, `Telemetry`, GRDB.
- `Sources/Orchestrator/StageRunner.swift` -- `run(stage:meetingID:activeState:work:)`; `.notify` under `.published` already allows `.awaitingVerification` in `Sources/Core/PipelineTransitions.swift`. No table change.
- `Sources/Persist/PersistStage+RerunTarget.swift:6` -- the `--rerun-<YYYY-MM-DD>[-N]` suffix pattern (private); re-derive it in Notifications, do not import `Persist`.
- `Sources/State/StateStore.swift:104` -- `fetchMeeting(id:)`, `vaultNotePath`.
- `Tests/PersistTests/PersistStageFixture.swift:11` -- in-memory store + `StageRunner` setup to copy.
- `App/Auricle/AuricleApp.swift` -- GUI composition root: build the notifier, install the delegate.
- `App/auricle-cli/AuricleCLI.swift` -- CLI composition root: a small factory that returns `StdoutNotifier`.
- `.swiftlint.yml:195` -- `print` rule; do not add exclusions.

## Tasks & Acceptance

**Execution:**
- `Sources/Notifications/Notifier.swift` -- `Notifier` protocol, `NotificationPayload`, `ObsidianURL` builder (vault-root name + relative file; a note outside the vault root falls back to `obsidian://open?path=<absolute path>`) -- shared by both conformers and the click handler.
- `Sources/Notifications/StdoutNotifier.swift` -- prints path then URL, one per line, through an injectable sink.
- `Sources/Notifications/UserNotificationNotifier.swift` -- posts through an injectable `NotificationCenterPosting` protocol (the real `UNUserNotificationCenter` adapter lives in `App/`); body text per re-publish rule; checks authorization first.
- `Sources/Notifications/NotifyStage.swift` -- `run(meetingID:title:notifier:stateStore:stageRunner:)` inside `StageRunner.run(stage: .notify, activeState: .published)`; reads `vaultNotePath`, fires, returns `.completed(targetState: .awaitingVerification)`. A missing note path skips the fire and still completes.
- `Sources/Notifications/NotificationClickHandler.swift` -- decodes `userInfo`, looks up `vault_note_path`, builds the URL, calls an injectable opener.
- `App/Auricle/NotificationDelegate.swift` -- `UNUserNotificationCenterDelegate` forwarding to the handler with `NSWorkspace.shared.open`.
- `App/Auricle/AuricleApp.swift`, `App/auricle-cli/AuricleCLI.swift` -- wire one conformer each.
- `Tests/NotificationsTests/` -- one file per type; cover every I/O row, including `-N` rerun ordinals, spaces and non-ASCII in paths, and payload round-trip keys.

**Acceptance Criteria:**
- Given the CLI composition root, when it builds a `Notifier`, then it is a `StdoutNotifier`; given the GUI root, a `UserNotificationNotifier`.
- Given a `published` meeting, when `NotifyStage` runs with a notifier that does nothing, then the state is `awaiting_verification` and `verified_at` stays null.
- Given a click on a known meeting, when the handler runs, then only the opener is called and the state stays `awaiting_verification`.

## Spec Change Log

## Review Triage Log

### 2026-09-20 — Review pass
- verdicts: 36 findings — high 0, medium 6, low 24, false 6, maybe-false 0
- findings:
    - `[false]` `[reject]` blind: no caller for NotifyStage/makeNotifier/makeCLINotifier — Spec Never-list bars RunVerb wiring; epics.md gives the in-process notify call to Story 4.7, and the GUI dispatch to Epic 6.
    - `[low]` `[reject]` blind: Telemetry dependency unused; Orchestrator edge puts a leaf above the orchestrator — Spec Code Map asked for Telemetry; Persist and Transcribe use the same Orchestrator edge; make check passed, so no cycle.
    - `[medium]` `[defer]` blind: delegate nil without vault or store, so willPresent is missing — GUI notifier is not wired until Epic 6; settle when the GUI dispatches.
    - `[medium]` `[defer]` blind: authorization request at fire time can raise a prompt from a background run; .ephemeral unhandled — Real for the GUI path, which is not live until Epic 6; ask at launch there.
    - `[low]` `[reject]` blind: no content.sound, no title, willPresent banner only — Cosmetic; spec fixes only the body text.
    - `[low]` `[reject]` blind: nil vaultNotePath completes without telling the maintainer — Spec I/O rule says skip fire and still complete; a warning is logged.
    - `[low]` `[reject]` blind: StdoutNotifier could corrupt --json output — No verb uses it yet; Story 4.7 owns the composition.
    - `[low]` `[reject]` blind: ObsidianURL vault name, symlink, root '/' and grapheme-count assumptions — Folder name is the default Obsidian vault name; other cases are unlikely and need extra guards.
    - `[low]` `[reject]` blind: schemaVersion is never checked — Spec only requires it in the payload; payload_version gates the click.
    - `[low]` `[reject]` blind: click failures are invisible to the maintainer; rawID vs meetingID log keys — Spec says log and continue; key naming is cosmetic.
    - `[low]` `[reject]` blind: weak log assertions, unused id binding, magic number, no invalid-date case — Lint passed; the tests verify each matrix row.
    - `[low]` `[reject]` blind: shared test helpers sit in NotifyStageTests.swift — Cosmetic.
    - `[low]` `[reject]` blind: launch-time click race with StateStore readiness — StateStore is opened before the delegate is installed in AuricleApp; no race shown.
    - `[low]` `[reject]` edge: empty-string vaultNotePath fires the notifier — Persist never writes an empty path.
    - `[low]` `[reject]` edge: retry after a failed transition re-fires the notifier — Stage retry is a pipeline concern; a duplicate banner or line is harmless.
    - `[medium]` `[defer]` edge: notDetermined authorization blocks the stage on a prompt — Same root as the blind authorization finding.
    - `[low]` `[reject]` edge: .ephemeral not treated as authorized; request error swallowed — GUI path is not live; negligible.
    - `[medium]` `[defer]` edge: no delegate when config or store fails — Same root as the blind delegate finding.
    - `[low]` `[reject]` edge: vault root '/' gives vault=%2F — Unlikely; the fix adds a guard.
    - `[low]` `[reject]` edge: relative note path or symlink and case differences — Persist stores absolute paths; unlikely.
    - `[low]` `[reject]` edge: note named '.md' or equal to vault root gives empty file= — Unlikely; fix adds a branch.
    - `[low]` `[reject]` edge: payload_version below current is rejected — Only version 1 exists.
    - `[low]` `[reject]` edge: meeting-ID notification identifier replaces an earlier notification — One live notification per meeting is a reasonable stub behavior.
    - `[low]` `[reject]` edge: willPresent lacks .sound — Cosmetic.
    - `[false]` `[reject]` edge claim: CLI never constructs StdoutNotifier — Same as blind row 1: wiring into RunVerb is Story 4.7.
    - `[false]` `[reject]` edge claim: GUI never builds UserNotificationNotifier — Same; the GUI dispatch is Epic 6.
    - `[medium]` `[patch]` edge claim: click test seeds `published` while the AC names `awaiting_verification` — Fixture takes a state argument; the click test now seeds and asserts `awaiting_verification`.
    - `[false]` `[reject]` edge deletion: ManifestPlaceholder removal breaks the target — Real sources now exist and make check passed; no cycle.
    - `[false]` `[reject]` gap: no caller for NotifyStage/makeNotifier/makeCLINotifier — Same as blind row 1.
    - `[low]` `[reject]` gap: AuricleApp.makeNotificationDelegate and didReceive are untested — AGENTS.md accepts thin App wrappers; decoding is covered in Sources.
    - `[medium]` `[defer]` gap: no delegate when Config or store fails, so banners drop — Same root as the blind delegate finding.
    - `[low]` `[reject]` gap: fetchMeeting-throws branch untested — Trivial catch branch.
    - `[low]` `[reject]` gap: unused id binding and no log assertion — Lint passed.
    - `[low]` `[reject]` gap: no test for note equal to root or trailing-slash root — Unlikely edge.
    - `[low]` `[defer]` gap: notify records no NotifyMeta (notification_id, delivered) — Story 4.9 ACs do not ask for it and the void `fire` cannot report delivery; Story 8.1's full Notifier owns it.
    - `[false]` `[reject]` intent-alignment: CLI/GUI wiring defined but unused; tests are library-level only — Descriptive report; matches the stub tag in the story text and the Never-list.

## Design Notes

The `Verify` and `Notifications` targets stay separate: the click handler here only opens Obsidian. Epic 8 adds the `markVerified` call beside the open, and the open must not depend on it succeeding.

## Verification

**Commands:**
- `swift build && swift test --filter NotificationsTests` -- expected: pass.
- `make check` -- expected: all gates green, including both Xcode schemes and the embedded `auricle-cli` assertion.
- `cd App && tuist generate --no-open` -- expected: only if `Project.swift` changes; it should not.

## Auto Run Result

Status: done

**Summary:** `Sources/Notifications` gains the `Notifier` protocol, `StdoutNotifier`, `UserNotificationNotifier`, `NotifyStage` (`published → awaiting_verification`), `NotificationClickHandler`, `NotificationPayload` and `ObsidianURL`. `App/` gains a thin click delegate, a `UNUserNotificationCenter` adapter and a CLI notifier factory.

**Files changed:**
- `Package.swift` -- `Notifications` gains `Orchestrator` and `Telemetry`; test target dependencies added.
- `Sources/Notifications/*` -- the types above; placeholder file deleted.
- `App/Auricle/NotificationDelegate.swift`, `App/Auricle/AuricleApp.swift` -- delegate and GUI notifier factory.
- `App/auricle-cli/NotifierFactory.swift` -- returns `StdoutNotifier`.
- `Tests/NotificationsTests/*` -- 19 tests in 5 suites.

**Review:** 36 findings. 1 patched (click test now seeds `awaiting_verification`). 2 deferred (GUI permission prompt and missing delegate; `NotifyMeta`). The rest were rejected for the reasons in the triage log.

**Follow-up review recommended:** false. One medium patched, no high.

**Verification:** `swift test --filter NotificationsTests` passed (19 tests). `make check` passed: every gate, both Xcode schemes, and the embedded `auricle-cli` assertion. All seven matrix rows are covered by passing tests.

**Residual risks:** No caller invokes `NotifyStage`, `makeCLINotifier` or `makeNotifier` yet (Story 4.7 and Epic 6). App-layer code is compile-checked only.
