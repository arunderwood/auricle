---
title: 'Story 5.9: self.wikilink Setup During Onboarding'
type: 'feature'
created: '2026-09-22'
status: 'done'
baseline_revision: '09d921497b485bdc3cd3e0c18e19bc110bbd3bb3'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/implementation-artifacts/epic-5-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Onboarding's Configure step has an inert `.selfWikilink` placeholder, so `self.wikilink` is never set and Epic 7's "This is me" affordance has no target. The summarize stage also takes the user's wikilink only from the calendar, so a configured value is ignored.

**Approach:** Replace the placeholder with a real sub-step in `OnboardingConfigureModel`. It pre-fills `[[<full user name>]]`, lets the user edit it, suggests matching page names from the chosen vault, and writes the confirmed value through `ConfigWriter` when onboarding finishes. Thread `Config.selfWikilink` into `SummarizeStage` so the configured value wins and the calendar value is the fallback.

## Boundaries & Constraints

**Always:**
- Logic lives in `Sources/AppUI` and `Sources/Summarize`. `App/` only renders and wires closures.
- `AppUI` keeps its dependencies `["Core", "Permissions"]`. Vault terms arrive through an injected closure that returns a `Core.Glossary`. `AuricleApp` supplies `VaultGlossaryBuilder`.
- Every new `OnboardingConfigureModel` init parameter is required, with no default. A test must never touch the real config file or Keychain.
- The write uses `ConfigWriter.set("self.wikilink", to:)` and happens in `finish()`, next to the `vault_path` write.
- The prefill is the configured `self.wikilink` when one exists. Otherwise it is `[[<full user name>]]`, with the link-syntax characters `[ ] | # ^ \` removed. A blank full name gives an empty prefill.

**Never:**
- Do not implement Epic 7's "Set me first…" state.
- Do not add a Skip to this sub-step. The epics AC has none.
- Do not scan the vault on the main actor.
- Do not change how `CalendarEnrichment` derives its own self identity.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Default | No configured value, full name `Jordan Lee` | Text is `[[Jordan Lee]]` | — |
| Configured prefill | Config has `[[Me]]` | Text is `[[Me]]` | — |
| Blank name | Full name is empty or whitespace | Text is empty | — |
| Bare text confirmed | `Jordan` | Stored as `[[Jordan]]`, advances to `.obsidian` | — |
| Wrapped text confirmed | `  [[Jordan]]  ` | Stored as `[[Jordan]]`, advances | — |
| Empty confirmed | `""`, `[[ ]]` | Stays on `.selfWikilink` | `SelfWikilinkError.empty` set and thrown |
| Stray brackets | `[[Jo]]n]]` or `Jo[n` | Stays on `.selfWikilink` | `SelfWikilinkError.malformed` set and thrown |
| Suggestions | Vault has `People/Jordan Lee.md`, `Jordanian Food.md`, `Other.md`; text `jord` | Suggests `Jordan Lee` before `Jordanian Food`; prefix matches before substring matches; people before uncategorized; at most 5 | — |
| No query | Text empty or `[[]]` | No suggestions | — |
| Pick suggestion | `selectSuggestion("Jordan Lee")` | Text becomes `[[Jordan Lee]]` | — |
| Finish | Confirmed `[[Jordan]]` | `writeSelfWikilink("[[Jordan]]")` called once, after `writeVaultPath` | Write error propagates from `finish()` |
| Stage precedence | Configured `[[Me]]`, calendar self `[[Ada Lovelace]]` | `summary.json` `self_wikilink` is `[[Me]]` | — |
| Stage fallback | Configured `nil`, calendar self `[[Ada Lovelace]]` | `self_wikilink` is `[[Ada Lovelace]]` | — |
| Stage, no event | Configured `[[Me]]`, calendar degraded | `self_wikilink` is `[[Me]]`, `needs_calendar_enrichment` stays true | — |

</intent-contract>

## Code Map

- `Sources/AppUI/OnboardingConfigureModel.swift` -- `ConfigureSubStep.selfWikilink` (line 25) and `advancePastSelfWikilinkPlaceholder()` (line 99) are the placeholder to replace. `finish()` (line ~133) writes `vault_path`. `defaultVaultDirectory` shows the configured-else-default prefill pattern.
- `App/Auricle/Onboarding/ConfigureStepView.swift` -- `selfWikilinkSubStep` (line ~49) is the placeholder view. Other sub-steps show the button and `accessibilityLabel` style.
- `App/Auricle/AuricleApp.swift:42-62` -- `makeOnboardingCoordinator()` is the composition root that builds every closure.
- `Sources/VaultGlossary/VaultGlossaryBuilder.swift:45` -- `init(vaultPath:meetingsSubdir:cacheRoot:)` and `buildOrEmpty()` return a `Glossary` of page names. `cacheRoot: nil` uses the app cache root, so tests pass a temp dir.
- `Sources/Core/Glossary.swift` -- `people`, `projects`, `concepts`, `uncategorized`.
- `Sources/Core/ConfigWriter.swift:59` -- `set(_:to:fileURL:homeDirectory:)`. `Sources/Core/Config.swift:76,150` -- `selfWikilink` reads `[self] wikilink`.
- `Sources/Summarize/SummaryArtifactMapper.swift:88-126` -- `artifact(...)` and `stubArtifact(...)` set `selfWikilink: match?.selfWikilink`.
- `Sources/Summarize/SummarizeStage.swift:47-150` -- both `run` overloads and `RunContext`. The stage body calls the mapper at lines ~185 and ~197.
- `Sources/Summarize/SummarizeWorker.swift:20` -- `run(...)` forwards to the stage.
- `Sources/Pipeline/InternalStageRouter.swift:53-70,158-175` -- `SummarizeDependencies` and `runSummarize`.
- `App/auricle-cli/Verbs/InternalStageWorker.swift:130` -- `summarizeDependencies(vaultPath:)` builds the dependencies. `calendarSource()` shows the `Config.load()` failure pattern.
- `Tests/AppUITests/OnboardingCoordinatorTests.swift:80-102,182-235` -- `advanceToAPIKeySubStep`, `makeConfigureModel`, and five tests call `advancePastSelfWikilinkPlaceholder()`.
- `Tests/SummarizeTests/CalendarDegradationTests.swift:100-170` -- stage tests with a matched event whose self is `[[Ada Lovelace]]`. Reuse their fixture and calendar-source doubles.
- `Tests/PipelineTests/InternalStageRouterTests.swift:106` -- the pattern for asserting a value reaches the summarize dependencies.

## Tasks & Acceptance

**Execution:**
- `Sources/AppUI/OnboardingConfigureModel.swift` -- remove the placeholder method and doc. Add `SelfWikilinkError { empty, malformed }`, `public var selfWikilinkText`, `selfWikilinkError`, `selfWikilink` (the confirmed value), `vaultTerms`, `selfWikilinkSuggestions`, `loadVaultTerms() async`, `selectSuggestion(_:)`, `confirmSelfWikilink() throws`, and a static `defaultSelfWikilink(fullUserName:)`. Add required init parameters `writeSelfWikilink`, `configuredSelfWikilink`, `fullUserName: String`, and `vaultTerms: @Sendable (URL) async -> Glossary`. `finish()` writes the confirmed value after `vault_path` when one exists -- replaces the placeholder with the real sub-step.
- `App/Auricle/Onboarding/ConfigureStepView.swift` -- render a title, a `TextField` bound to `selfWikilinkText`, suggestion buttons calling `selectSuggestion`, the error text, and a Continue button calling `confirmSelfWikilink()`. Call `loadVaultTerms()` from `.task` -- view only.
- `App/Auricle/AuricleApp.swift` -- supply `writeSelfWikilink: { try ConfigWriter.set("self.wikilink", to: $0) }`, `configuredSelfWikilink: { (try? Config.load())?.selfWikilink }`, `fullUserName: NSFullUserName()`, and `vaultTerms` running `VaultGlossaryBuilder(vaultPath:).buildOrEmpty()` in a detached task -- composition root.
- `Sources/Summarize/SummaryArtifactMapper.swift` -- add `configuredSelfWikilink: String? = nil` to `artifact` and `stubArtifact`. Use `configuredSelfWikilink ?? match?.selfWikilink` -- the precedence rule in one place.
- `Sources/Summarize/SummarizeStage.swift`, `Sources/Summarize/SummarizeWorker.swift` -- add `selfWikilink: String? = nil` to each `run`, carry it in `RunContext`, and pass it to both mapper calls -- threads the configured value.
- `Sources/Pipeline/InternalStageRouter.swift` -- add `selfWikilink: String?` to `SummarizeDependencies` (init default `nil`) and pass it in `runSummarize` -- router wiring.
- `App/auricle-cli/Verbs/InternalStageWorker.swift` -- pass `selfWikilink: (try? Config.load())?.selfWikilink` -- production wiring.
- `Tests/AppUITests/OnboardingCoordinatorTests.swift` -- update `makeConfigureModel` and the placeholder calls to use `confirmSelfWikilink()`. Assert that `finish()` writes `self.wikilink`.
- `Tests/AppUITests/SelfWikilinkStepTests.swift` -- new. Cover every onboarding row of the I/O matrix. The round-trip test writes through `ConfigWriter.set` into a temp home and reads back `Config.load(homeDirectory:).selfWikilink`. The suggestion test builds a synthetic vault on disk and passes a real `VaultGlossaryBuilder` with a temp `cacheRoot`.
- `Package.swift` -- add `"Core"` and `"VaultGlossary"` to the `AppUITests` dependencies. `AppUI`'s own dependencies stay unchanged.
- `Tests/SummarizeTests/CalendarDegradationTests.swift` -- add the three stage-precedence rows, asserting on the written `summary.json`.
- `Tests/PipelineTests/InternalStageRouterTests.swift` -- mirror `publishAnywayReachesTheSummarizeWorker` with `publishAnyway: true` and a `Probe` whose `SummarizeDependencies` carry `selfWikilink: "[[Me]]"`. Assert that the stub `summary.json` has `self_wikilink` `[[Me]]` -- proves the router forwards the value.

**Acceptance Criteria:**
- Given the Configure step past the vault picker, when the `self.wikilink` sub-step renders, then it shows the prefilled value, accepts edits, and lists matching vault page names.
- Given a confirmed value, when Done runs `completeOnboarding()`, then `~/.auricle/config.toml` gains `self.wikilink` through `ConfigWriter`, and `Config.selfWikilink` reads it back.
- Given a configured `self.wikilink` and a calendar self identity, when summarize runs, then the configured value is written. With no configured value, the calendar value is written.
- Given `swift test`, then `AppUITests`, `SummarizeTests`, and `PipelineTests` pass.

## Spec Change Log

## Review Triage Log

### 2026-09-22 — Review pass
- verdicts: 26 findings — high 0, medium 5, low 14, false 7, maybe-false 0
- findings:
  - `[medium]` `[patch]` blind-hunter: a configured `self.wikilink` that differs from the calendar self leaves the calendar self in `attendees`, so `FilenameResolver.attendeeSlug` no longer filters the user out (`with-ada-lovelace-and-ben-ng`). — patch: `SummaryArtifactMapper.attendees(of:configuredSelfWikilink:)` replaces the calendar self entry with the configured link in both `artifact` and `stubArtifact`; test expectation updated to `["[[Me]]", "[[Ben Ng]]"]`.
  - `[low]` `[reject]` blind-hunter: `confirmSelfWikilink` accepts `[[|alias]]` (empty target) and `#`/`^` suffixes. — `#`/`^` still link to the named page; an empty-target alias is an unlikely entry, and the fix adds a validation branch.
  - `[low]` `[reject]` blind-hunter: a hand-edited bare `self.wikilink` is not normalized on the pipeline read path. — `WikilinkParts` already strips optional brackets for the self filter; the remaining harm is cosmetic frontmatter for an off-docs hand edit, and the fix adds a shared `Core` helper.
  - `[false]` `[reject]` blind-hunter: `InternalStageWorker` drops a config parse error silently. — `calendarSource()` loads the same file in the same call and writes a stderr line on failure, so the failure is logged.
  - `[low]` `[reject]` blind-hunter: `defaultSelfWikilink` duplicates `CalendarEnrichment.sanitizedName` with different whitespace/`@` rules. — `NSFullUserName()` with tabs or `@` is unlikely; sharing needs a cross-module move.
  - `[low]` `[reject]` blind-hunter: `selfWikilinkError` stays visible while the user edits after a refusal. — cosmetic, only after an error; it clears on the next successful Continue.
  - `[low]` `[reject]` blind-hunter: a bare name in the field is still offered as a suggestion. — clicking it wraps the name, which is harmless and useful.
  - `[low]` `[reject]` blind-hunter: word-start matching ignores `-` and `_`. — such names still match as substrings; ranking only.
  - `[false]` `[reject]` blind-hunter: `loadVaultTerms()` can apply stale results after the vault changes. — Configure sub-steps are forward-only, so `vaultPath` cannot change once `.selfWikilink` is reached.
  - `[low]` `[reject]` blind-hunter: `loadVaultTerms()`'s no-vault no-op is untested. — a one-line guard; a test adds little.
  - `[false]` `[reject]` blind-hunter: `stubArtifact` with a configured value and no match has no test. — `theConfiguredSelfWikilinkReachesTheSummarizeWorker` runs exactly that path and asserts `self_wikilink`.
  - `[medium]` `[patch]` blind-hunter: no test pairs a configured self with a calendar self and checks the attendee list. — patch: same root cause as the first row; both calendar-self tests now assert the mapped attendees.
  - `[medium]` `[patch]` edge-case-hunter: configured self differs from the calendar self, so the user's calendar name stays in the filename slug. — patch: same fix as the first row.
  - `[low]` `[reject]` edge-case-hunter: a whitespace-only hand-edited `self.wikilink` replaces a valid calendar self. — `Config.nonEmpty` passes it through, but a whitespace-only value is an unlikely hand edit.
  - `[low]` `[reject]` edge-case-hunter: `confirmSelfWikilink` accepts `[[|alias]]`, `Jordan#Lee`, `Jo^n`. — same as the blind-hunter row above.
  - `[low]` `[reject]` edge-case-hunter: a whitespace-only configured value prefills a blank field. — unlikely hand edit; the user sees the blank field and types a name.
  - `[false]` `[reject]` edge-case-hunter: the detached vault walk can repeat or land late after the view reappears. — the sub-step appears once in a forward-only sequence and `vaultPath` cannot change.
  - `[low]` `[reject]` edge-case-hunter: the current name in bare or differently cased form is still suggested. — same as the blind-hunter row above.
  - `[low]` `[reject]` edge-case-hunter: `finish()` leaves `vault_path` written when the `self.wikilink` write fails. — `DoneStepView` already offers a retry and both writes are idempotent, the precedent Story 5.7 accepted.
  - `[false]` `[reject]` edge-case-hunter: a malformed config drops the configured self silently. — same refutation as the blind-hunter row: `calendarSource()` logs the load failure.
  - `[medium]` `[patch]` verification-gap: the stub path with a calendar match plus a configured value is untested. — patch: added `aConfiguredSelfWikilinkWinsOverTheCalendarSelfInThePublishAnywayStub`.
  - `[medium]` `[patch]` verification-gap: `SummarizeDependencies.init`'s `selfWikilink = nil` default lets the CLI omit the argument unnoticed. — patch: default removed; the compiler now enforces the argument at the production site.
  - `[low]` `[reject]` verification-gap: the `AuricleApp` composition-root closures are untested. — the known `App/` coverage limit (AGENTS.md pitfall), the same pattern `vault_path` uses; closing it is a structural change.
  - `[low]` `[reject]` intent-alignment: the SwiftUI view and `NSFullUserName` wiring have no automated coverage. — same `App/` coverage limit; the logic is in `AppUI` and covered.
  - `[false]` `[reject]` intent-alignment: precedence is applied only in summarize, not in Epic 7 consumers. — no Epic 7 consumer exists yet; summarize is the only stage that emits a self identity today.
  - `[false]` `[reject]` intent-alignment: the ship step and branch name cannot be judged from the diff. — not a defect in the diff; the ship step moves the work to a `feat/` branch.

### 2026-09-22 — PR #120 review (Epic 5 overview session)
- verdicts: 5 findings — high 0, medium 4, low 1, false 0, maybe-false 0
- findings:
  - `[medium]` `[patch]` epic-5-overview: the diff rewrote `epic-5-context.md`, dropping detail (the verified-deep-link rule, why `WAVWriter` is not atomic) and conflicting with #119. — patch: restored main's version; only the Configure sub-step order line changes, to match the shipped order (vault path, `self.wikilink`, Obsidian, API key).
  - `[medium]` `[patch]` epic-5-overview: `AttributionViewModel.markThisIsMe()` takes its name only from the calendar `isSelf` attendee. This corrects the earlier `false` row that said no Epic 7 consumer exists. — patch: `AttributionViewModel.init` takes `configuredSelfWikilink`, and `selfName` prefers its bare name over the calendar; tests added. No production caller builds the view model yet; the Epic 7 sheet passes `Config.selfWikilink` when it does.
  - `[medium]` `[patch]` epic-5-overview: a `self.wikilink` set outside onboarding (`auricle config set self.wikilink "Jordan"`) flows through raw, so summarize writes a bare `Jordan`. This corrects the earlier `low` rejection of the same point. — patch: one `Core.SelfWikilink.normalized` helper, used by `Config.parse` (an invalid value throws `invalidValue`), `ConfigWriter.set`, onboarding and `SummaryArtifactMapper`.
  - `[medium]` `[patch]` epic-5-overview: typed validation rejected only `[`/`]`, so `[[|me]]` (empty target) got past it and left the user's name in the filename. This corrects the earlier `low` rejection. — patch: `normalized` rejects `| # ^ \`, newlines and control characters in the target, and an empty target; aliases are no longer accepted.
  - `[low]` `[patch]` epic-5-overview: the spec was marked `done` before lint, swift and app CI were green. — patch: status is `in-review` until CI passes on the rebased branch.

## Design Notes

Suggestion order: `people` first, then `uncategorized`. `projects` and `concepts` are left out because they never name a person. Within each group, a case-insensitive prefix match on the full name or any word comes before a substring match, and alphabetical order breaks ties. The query is the text with a surrounding `[[`/`]]` and any `|alias` removed. A candidate whose `[[name]]` equals the current text is left out.

`ConfigWriter` quotes the value as a TOML string. `[self]`-table reads already work (`ConfigTests`), and `ConfigWriterTests` covers the `self.wikilink` dotted-key write.

## Verification

**Commands:**
- `swift build --explicit-target-dependency-import-check error` -- expected: clean.
- `swift test --filter 'AppUITests|SummarizeTests|PipelineTests'` -- expected: all pass.
- `cd App && tuist generate --no-open && cd .. && xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp build` -- expected: `BUILD SUCCEEDED`.
- `mise exec -- swiftformat --lint Sources Tests App` and `mise exec -- swiftlint lint --strict --quiet` -- expected: no violations.

## Auto Run Result

**Summary:** The Configure step's `self.wikilink` sub-step is real. It pre-fills the configured value or `[[<full user name>]]`, accepts edits, suggests vault page names (people first, then uncategorized; prefix before substring; at most 5), and `finish()` writes the confirmed `[[…]]` value through `ConfigWriter` after `vault_path`. The summarize stage takes the configured value over the calendar self identity, and maps the calendar self attendee to it so persist still filters the user out of the filename.

**Files changed:**
- `Sources/AppUI/OnboardingConfigureModel.swift` -- the sub-step model: prefill, validation, suggestions, `loadVaultTerms()`, write in `finish()`.
- `App/Auricle/Onboarding/ConfigureStepView.swift` -- field, suggestion buttons, error text, Continue.
- `App/Auricle/AuricleApp.swift` -- wires `ConfigWriter`, `Config.load`, `NSFullUserName()`, and a detached `VaultGlossaryBuilder` scan.
- `Sources/Summarize/SummaryArtifactMapper.swift` -- configured-wins precedence and the self-attendee mapping.
- `Sources/Summarize/SummarizeStage.swift`, `SummarizeWorker.swift`, `Sources/Pipeline/InternalStageRouter.swift`, `App/auricle-cli/Verbs/InternalStageWorker.swift` -- thread `selfWikilink` from config to the stage.
- `Package.swift` -- `AppUITests` gains `Core` and `VaultGlossary`.
- `Tests/AppUITests/SelfWikilinkStepTests.swift` (new), `OnboardingCoordinatorTests.swift`, `Tests/SummarizeTests/CalendarDegradationTests.swift`, `SummarizeStageFixture.swift`, `Tests/PipelineTests/InternalStageRouterTests.swift` -- coverage for every I/O matrix row.

**Review findings breakdown:**
- Patched (3 entries, all medium): the configured self left the calendar self in `attendees`, breaking the filename self filter (3 rows, one root cause); the publish-anyway stub path with a match was untested; `SummarizeDependencies.init`'s `nil` default let the CLI drop the value silently.
- Deferred: none.
- Rejected: 14 low and 7 false, each with its reason in the Review Triage Log. The lows are unlikely inputs (empty-target alias, whitespace-only hand edits, tab or `@` in the account name), cosmetic UI state, suggestion ranking, and the known `App/` coverage limit. The falses are refuted by `calendarSource()`'s stderr line, the forward-only sub-step order, and an existing router stub test.

**Follow-up review recommendation:** `true` — 3 medium entries were patched on a first pass. Named risk: the attendee mapping changes what the note's `attendees` frontmatter holds when a configured self differs from the calendar name. It is covered at `summary.json` level, but no persist-level test renders the resulting filename.

**Verification performed:**
- `swift build --explicit-target-dependency-import-check error` -- clean.
- `swift test --filter 'AppUITests|SummarizeTests|PipelineTests'` -- 336 tests pass, all matrix-row tests included.
- `swiftformat --lint .` and `swiftlint lint --strict --quiet` -- no violations.
- `tuist generate`, then `xcodebuild` for `AuricleApp` and `auricle-cli` -- `BUILD SUCCEEDED`.

**Residual risks:**
- The SwiftUI sub-step and the `AuricleApp` closures have no automated coverage (`App/` is outside `swift test`). Nobody has clicked through onboarding.
- A hand-edited `self.wikilink` is used as written, with no normalization.
