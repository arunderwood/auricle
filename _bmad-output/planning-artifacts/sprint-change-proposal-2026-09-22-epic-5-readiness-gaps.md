---
date: 2026-09-22
project: auricle
workflow: correct-course
trigger_story: none (Epic 5 is backlog; found by the readiness gate run after Epic 4 closed)
scope_classification: moderate
status: applied
applied: 2026-09-22
artifacts_affected:
  - _bmad-output/planning-artifacts/epics.md
  - _bmad-output/planning-artifacts/architecture.md
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/ux-design-specification.md
  - _bmad-output/implementation-artifacts/sprint-status.yaml
  - _bmad-output/implementation-artifacts/deferred-work.md
  - _bmad-output/implementation-artifacts/epic-5-context.md
  - AGENTS.md
---

# Sprint Change Proposal — Epic 5 Readiness Gaps

## 1. Issue Summary

### Problem statement

The readiness gate for Epic 5 returned **FAIL**. Five of the nine stories depended on decisions that no artifact recorded, and a developer would have had to invent them. All gaps are in plan text. No Epic 5 code exists beyond the empty `Capture` and `Permissions` targets, the `AudioImporter`, and the CLI verb stubs.

| # | Gap | Where |
|---|---|---|
| 1 | The system-audio capture API was never chosen against current macOS behavior | Stories 5.1, 5.2, 5.8; Decisions 1.4 and 4.4 |
| 2 | Capture cannot run through `StageRunner.run`, and there is no `StateStore` call that inserts the `recording` row | Story 5.4; `StageRunner.swift`, `PipelineTransitions.swift` |
| 3 | Nothing recovers a meeting stuck in `recording` after a crash | Decision 1.2 crash-recovery list |
| 4 | It was unrecorded which process hosts capture and how `auricle stop` reaches it | Decision 1.1; `RecordVerb`, `StopVerb` |
| 5 | Nothing said who dispatches transcribe after `captured` | Stories 5.4, 5.6 |
| 6 | There was no config writer and no `self.wikilink` key | Stories 5.7, 5.9; `Config.swift`, `ConfigVerb` |
| 7 | App-only logic has no test target (`Tests/AppTests` does not exist) | Stories 5.5, 5.7, 5.8, 5.9 |
| 8 | Story 5.5 asked for snapshot tests with no snapshot library | Story 5.5; `Package.swift` |
| 9 | Story 5.1's lint rule would reject existing code in `NotificationDelegate.swift` | Story 5.1 |
| 10 | Story 5.1's API could not be built as written: sync `check` versus async notification status, and a non-optional URL with a nil case | Story 5.1 |
| 11 | Story 5.8's mic Skip contradicted Story 5.2's permission error | Stories 5.2, 5.8 |
| 12 | A streamed `WAVWriter` conflicts with the `AtomicWriter` rule | Story 5.3; AGENTS.md |
| 13 | Onboarding keyed on config-file presence, which the maintainer already has | Story 5.7 |
| 14 | Forward dependencies on Epics 6, 7 and 9 were described as absent | Stories 5.5, 5.7, 5.9 |
| 15 | `capture_time_zone` was missing from `architecture.md`, and re-run dates used the wrong zone | `deferred-work.md` (two entries) |
| 16 | Smaller items | See section 3 |

### How it was discovered

1. The Epic 4 retro closed on main (PR #109).
2. A read-only readiness audit then ran against the Epic 5 stories, `architecture.md`, `prd.md`, the UX spec, `deferred-work.md` and the current `Sources/`, `App/`, `Package.swift`, `.swiftlint.yml` and `scripts/check.sh`.
3. Gap 1 was researched separately with `bmad-deep-recon`: `research/technical-scstream-vs-core-audio-process-taps-2026-09-22/research.md`, with 33 cited sources.

## 2. Decisions

| # | Decision | Basis |
|---|---|---|
| D1 | System audio comes from a Core Audio **global process tap** that excludes auricle's own process. The mic comes from AVAudioEngine. A `SystemAudioSource` seam keeps ScreenCaptureKit as the fallback. | Research: a narrower TCC grant, no recurring re-prompt found, and an honest privacy indicator. Weighted 33 to 29 over SCStream. |
| D2 | The minimum macOS rises from 14.0 to **14.4**, the process-tap floor. Development targets the current release. | The maintainer ruled "target latest"; 14.4 is the lowest version the API allows |
| D3 | `TCCCategory.screenCapture` becomes `.systemAudioCapture`. `PermissionStatus` gains `.unknown`. `check` and `request` are async. The deep link is `URL?`. | macOS has no public API to read or request the tap grant |
| D4 | `NSAudioCaptureUsageDescription` goes in as a literal Info.plist key, and `scripts/check.sh app` asserts it. `NSScreenCaptureUsageDescription` is removed. | A missing key fails silently with zero buffers |
| D5 | A 30s exact-zero watchdog does a full rebuild, never fails the capture, and counts what it does. Story 5.2 carries a manual live-app gate and a 60-minute soak. | An open zero-buffer report on a macOS 26 beta, and the tap's evidence gap on Teams and Meet |
| D6 | Capture runs in the GUI process only in Epic 5. The CLI `record` and `stop` verbs stay stubs. Story 9.5 decides how they reach the app without XPC. | Decision 1.1, and TCC grants belong to `com.auricle.app` |
| D7 | Capture bypasses `StageRunner.run` through `StateStore.beginCapture` and `finishCapture`, plus a `(.capture, .recording)` transition entry | The runner wraps one closure over an existing row |
| D8 | On launch, an orphaned `recording` row is recovered: header repair then `captured`, or `capture_failed` with reason `interrupted` | DP3: audio is the only recovery layer |
| D9 | After `captured`, the GUI runs `PipelineRunner` in-process with `to: .reviewDiarization` | `PipelineRunner` is the only driver, and attribution needs the user |
| D10 | Nothing blocks a start. A denied mic records system audio only. System Audio status is unknowable. | Follows from D3 |
| D11 | `WAVWriter` is the one recorded exemption from `AtomicWriter`: a `FileHandle` stream with the header patched on finalize and on recovery | A 115 MB stream that must survive partially |
| D12 | A new `AppUI` SwiftPM target holds GUI view models and components with logic. `App/` holds views and wiring. No snapshot dependency is added. | The AGENTS.md pitfall: `App/` logic is untested |
| D13 | A new Story 5.10 adds a key-preserving `ConfigWriter`, the `self.wikilink` key, and `auricle config set` | FR59: the maintainer edits the config by hand |
| D14 | Onboarding keys on a completion marker in Application Support | The maintainer already has a config file |
| D15 | A configured `self.wikilink` wins over the calendar-derived identity. The default comes from `NSFullUserName()`. Onboarding has no calendar step in MVP. | No calendar connection exists during onboarding |
| D16 | A revocation the OS reports notifies through `Notifier.fireCaptureFailed`, and logs if notifications are denied | NFR-R8 |
| D17 | The empty list moves to Story 6.3 and the post-onboarding doctor run to Story 9.2. The indicator shows in the window toolbar until Story 6.2. | They depend on the main window (Epic 6) and Doctor (Epic 9) |

## 3. Changes Applied

**`epics.md`**
- **Epic 5 section:** stories 5.1–5.9 rewritten, Story 5.10 added, and the summary rewritten with the build order and the forward references.
- **Epic List entry for Epic 5:** capture backend, FR60, and UX-DR43 removed.
- **FR6 and FR60:** "System Audio Recording" replaces "Screen Recording".
- **AR-FAIL-6, UX-DR41, UX-DR42, UX-DR44, UX-DR45** updated.
- **FR coverage map:** the FR4 and FR6 rows updated.
- **Story 6.2:** moves the indicator.
- **Story 9.2:** the System Audio check reads `?`, and a silent run happens after onboarding.
- **Story 9.5:** `record` and `stop` must reach the app, and the story reconciles `--replace`.

**`architecture.md`**
- **Decision 1.1:** capture host, and TCC ownership.
- **Decision 1.2:** capture recovery.
- **Decision 1.4:** capture backend and the `WAVWriter` exemption.
- **Schema:** the `meetings.capture_time_zone` column and its write-authority row.
- **Decision 2.4:** the filename-date zone.
- **Decision 4.4:** the permission table, detection points, revocation copy, Info.plist table, and the doctor examples.
- **Also updated:** the external-dependency list, the typed-error example, the source tree (`ProcessTapSource`, `SystemAudioSource`, `CaptureStage`, `AppUI`), the failure table, and the sandbox rationale.

**`prd.md`**
- Updated: target OS, the capture dependency, the TCC summary, the capture scope bullets, FR6, FR60, J0, and the macOS floor.
- Narrative mentions of ScreenCaptureKit in the product story are left as written.

**`ux-design-specification.md`**
- Updated: the J0 flowchart, the J0 key details, the Doctor copy, and the critical-interaction line.

**Tracking and supporting files**
- **`sprint-status.yaml`:** regenerated with `sprint_plan.py`. Eight Epic 5 keys were renamed with their story titles, all still `backlog`, and `5-10-configwriter-self-wikilink-key` was added.
- **`deferred-work.md`:** the two `capture_time_zone` entries are closed by plan, and the signing entry is added.
- **`epic-5-context.md`:** compiled for `bmad-build`.
- **`AGENTS.md`:** the `AtomicWriter` convention names the one exemption.

**Smaller items folded in**
- NFR-P11 gets a measurement criterion in 5.4. The NFR-Pr6 credit and the Dock-indicator claim are removed.
- 5.1 verifies the Info.plist strings, adds the trailing periods, and settles `NSUserNotificationsUsageDescription`.
- 5.3 names `CacheArtifactWriter.cacheDirectory(for:)` and `AudioImporter.audioFileName`, and requires a 0700 directory.
- The Obsidian check opens a URL only and writes no test note.

## 4. Open Maintainer Decisions

1. **Debug signing.** Ad-hoc Debug builds likely make TCC re-prompt on every rebuild, and may block a GUI-written Keychain item from being read by the `com.auricle.cli` worker. This is an inference; Story 5.2's soak confirms it. The choice:
   - keep Debug ad-hoc until Story 9.3, or
   - pull the Story 9.3 signing identity forward for Debug builds.

   `architecture.md` already says TCC stability needs that identity. Tracked in `deferred-work.md`.
2. **Capture fallback trigger.** If Story 5.2's live check misses Teams, Meet or Zoom audio, the story stops and a correct-course switches `SystemAudioSource` to ScreenCaptureKit. That adds the Screen Recording grant back into 5.1 and 5.8.

## 5. Verification

- `sprint_plan.py generate` reported no illegal entries. Its three warnings are pre-existing non-epic headings.
- `recon_kit.py citations` reports no dangling markers or orphan rows in the research report.
- Every replacement in `epics.md`, `architecture.md`, `prd.md` and the UX spec was applied by exact match, one occurrence each.
