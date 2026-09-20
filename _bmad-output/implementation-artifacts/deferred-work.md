# Deferred Work

Append-only. Each entry records a finding routed to `defer` during a review pass. Do not modify existing entries or look for duplicates.

An entry that starts with `closes:` marks an earlier entry resolved. It names the earlier entry's `source_spec` and the opening words of its `summary`, then says how it closed and where the fix lives. The earlier entry stays as written. An entry with no matching `closes:` is open.

Story 3.8's spec was renamed to `spec-3-8-strategy-comparison-rig-scaffold.md`. Entries that cite `spec-3-8-smoke-test-rig-scaffold.md` mean that file.

- source_spec: `_bmad-output/implementation-artifacts/1-1-project-initialization-xcode-swiftpm-hybrid.md`
  summary: Story status vocabulary disagrees across tracking files — the story file's `Status` field uses bmad-build's enum (draft/ready-for-dev/in-progress/in-review/done) while `sprint-status.yaml` uses its own documented enum (backlog/ready-for-dev/in-progress/review/done); the same story state is now named `in-review` in one file and `review` in the other.
  evidence: Verified in both files. Each value is correct per its own file's schema comment, so this isn't a bug in either file — it's a structural mismatch between two coexisting BMAD tracking conventions in this repo, predating this story. Reconciling it means picking one canonical vocabulary or adding a mapping between the two skill families, which is outside any single story's scope.

- source_spec: `_bmad-output/implementation-artifacts/1-1-project-initialization-xcode-swiftpm-hybrid.md`
  summary: `NSUserNotificationsUsageDescription`'s effect on the macOS runtime permission prompt is asserted as fact in `AuricleApp.swift`'s comment and the Dev Agent Record, but was not independently confirmed against current Apple documentation or an on-device run.
  evidence: If the key does not actually gate the prompt text as claimed, UX-DR44's locked user-voice copy silently never displays to the user — a real UX regression (medium if true) but not one that breaks any build/test gate, so it wasn't caught here. Settled by: requesting notification authorization in a running build on macOS 14 and confirming the shown description text matches the locked copy.

- source_spec: `_bmad-output/implementation-artifacts/1-2-core-primitives-atomicwriter-ids-canonicaltranscript-dialects-config.md`
  summary: Implement `CanonicalTranscript` (NFC/LF/`<Speaker_N>:` normalization, UTF-8 byte-offset round-trip contract, AR-SUM-4) as its own follow-up story.
  evidence: Story 1.2's full spec (bundling all 6 epics.md-titled primitives) ran to ~2,700 tokens, over the 1,600-token soft ceiling. CanonicalTranscript's first real consumer is Epic 3 (Summarizer/quote-grounding) and Epic 4 (Diarize/Attribute), not any of the remaining Epic 1 stories (1.3-1.8), so deferring it does not block Epic 1's own sequencing.

- source_spec: `_bmad-output/implementation-artifacts/1-2-core-primitives-atomicwriter-ids-canonicaltranscript-dialects-config.md`
  summary: Implement `Core/Config.swift` (typed TOML accessors for the FR58 key set, tilde/symlink normalization, Keychain-exclusion of secrets) as its own follow-up story.
  evidence: Same token-budget split as the CanonicalTranscript deferral above. Config's first real consumers are Epic 5 (onboarding/vault picker) and Epic 9 (Settings UI); none of the remaining Epic 1 stories (1.3-1.8) read or write config, so deferring it does not block Epic 1's sequencing.

- source_spec: `_bmad-output/implementation-artifacts/1-2-core-primitives-atomicwriter-ids-canonicaltranscript-dialects-config.md`
  summary: sprint-status.yaml moves a story directly from `backlog` to `in-progress`, skipping the `ready-for-dev` status its own header comments define as "story file created in stories folder."
  evidence: Same root cause as the tracking-vocabulary-mismatch entry already logged for Story 1.1: sync-sprint-status.md sets development_status directly to whatever target_status bmad-build passes, with no intermediate ready-for-dev step. This is the workflow's own designed behavior, not something this story's content caused, and will recur for every future story that goes through bmad-build's implement step.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-ulid-dependency-swap.md`
  summary: The spec's frozen Intent describes `yaslab/ULID.swift` as "actively maintained," which overstates what the repo's history shows.
  evidence: Verified via GitHub API: the latest tagged release (1.3.1) is from 2024-08-11, over two years before this change. There is more recent commit activity (a CI fix merged 2026-07-05) and the repo isn't archived, so it isn't abandoned — but "actively maintained" implies a cadence the release history doesn't back up. Cosmetic wording issue with no functional impact; left as-is because it sits inside the spec's `<frozen-after-approval>` block, which this workflow step cannot edit.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-2-ulid-dependency-swap.md`
  summary: Add a golden/fixed-output test pinning `ULIDFormat.generate`'s exact output for a known input (e.g. timestamp `0`), so a future semver-compatible bump of `yaslab/ULID.swift` that changed the wire format would be caught.
  evidence: Current tests only assert structural properties (length, alphabet membership, lexical sort order), not an exact string for a fixed input. `MeetingID` strings are persisted (SQLite, notification payloads, vault frontmatter), so a silent format drift would be a real problem if it happened — but a semver-compatible release changing output format would itself be a bug in the dependency, making this a low-probability event worth guarding cheaply later rather than blocking this change on now.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-3-log-facade-with-sensitivity-tagging-and-redaction.md`
  summary: Confirm whether `Logger.warning(...)` and `Logger.notice(...)` (what Story 1.3's `Log.warn` currently calls) actually differ in `log show`/Console filtering visibility, and switch `warn` to `.warning` if they do.
  evidence: The mapping was a deliberate, documented choice (Design Notes), but no test can distinguish the two OSLogTypes since neither crashes, and their real operational-visibility difference wasn't verified against current OSLog behavior — which matters given NFR-M3 names `log show` as the canonical operational surface. If they differ, defaulting to the less-visible level would be medium severity.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-3-log-facade-with-sensitivity-tagging-and-redaction.md`
  summary: No test exercises the public `Log.debug/.info/.warn/.error` entry points with a `.sensitive` field — only the internal `Log.buildMessage` is tested directly — so a future edit that stopped routing those methods through `buildMessage` would reintroduce raw sensitive data into real logging calls with the full test suite still green.
  evidence: Verified via `swift test --filter CoreTests` (25/25 pass) and grepping `Tests/` — no `.sensitive` field is ever passed through `log.debug/info/warn/error` in the test suite. Closing this needs an injectable `Logger` sink so tests can assert what actually reaches the logger, which is a larger redesign than this facade story scopes — likely alongside Story 1.6 or 1.8.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-3-log-facade-with-sensitivity-tagging-and-redaction.md`
  summary: The I/O Matrix's "`debug` outside a DEBUG build" row (verifying `debug()` compiles to nothing in release) was checked once manually via `swift build -c release --target Core`; nothing re-runs that check automatically, so a future removal of the `#if DEBUG` guard would ship undetected.
  evidence: Confirmed no CI, Makefile, or scripts exist yet in this repo to wire this in. Story 1.8 (lint/format/CI enforcement layer) is the explicitly scoped owner of adding a release-config build step to CI.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-8-smoke-test-rig-scaffold.md`
  summary: Assemble >=5 real meeting transcripts (>=1 1:1, >=1 with >=4 attendees) as CanonicalTranscript JSON and run `Tests/scripts/run-smoke-test.sh` against them.
  evidence: Needs the maintainer's own recordings and live Anthropic spend, so it was excluded from the rig scaffold. WhisperKitTranscriber (Epic 4) is not built, so transcripts must come from another source converted to CanonicalTranscript JSON (`text` + `utterances`, UTF-8 byte offsets).

- source_spec: `_bmad-output/implementation-artifacts/spec-3-8-smoke-test-rig-scaffold.md`
  summary: Score recall, precision (false-keeps) and quote quality per transcript by hand, apply Story 3.8's default-flip rule, and record the outcome and rationale in `Tests/fixtures/smoke-test-results.md`.
  evidence: Recall is "items present in the user's memory of the meeting" and quote quality is "did it read sensibly" -- maintainer judgments the rig cannot compute. Until this is done, Story 3.8's default lock-in is open.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-8-smoke-test-rig-scaffold.md`
  summary: Wire `SummarizerOrchestrator(primary:fallback:)` in the composition roots (`AuricleApp.swift`, auricle-cli) from the locked-in default.
  evidence: Depends on the human run above. Story 3.7 uses an interim default (Citations primary, substring fallback, per Decision 3.6's stated MVP default) until the run happens.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: Record `summarization_prompt_set_hash` in telemetry (epics.md:1421 assigns it to the summarize stage).
  evidence: No telemetry column or `State.Telemetry` field exists (needs a migration), and the strategies discard `SummarizationPrompt.promptSetHash`, so neither `SummaryWithGrounding` nor `SummarizerOrchestrator.Outcome` can surface it. The hash also differs per mode, so it depends on which strategy answered.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: Thread `--prompt-dir` into the prompt.
  evidence: `ClaudeCitationsSummarizer` hard-codes `promptDir: nil`, and `SummarizerStrategy.summarize` and `SummarizerConfig` have no channel for it. Attendees are threaded by Story 3.11 through `SummarizerConfig.attendeeNames`.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: A multi-line `quote` renders as a broken blockquote in the vault note.
  evidence: `FrontmatterRenderer.swift:100` prefixes only the first line with `> `, and Citations pointers span whole utterances, so a multi-utterance quote contains `\n`. The stage emits the exact transcript slice, as the AC requires; the renderer fix belongs to Persist.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: Apply `segment_overrides`/`segment_splits` from `attribution.json`.
  evidence: They reference `diarization.json` segment ids, which have no Swift type and no mapping to utterance indices. The stage reads only `speakers`.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: Whether an utterance's `[start,end)` range includes the `<Speaker_N>: ` prefix is undefined until the transcribe stage exists.
  evidence: Decision 3.4 (architecture.md:1439) says the text prefixes each utterance; existing test fixtures disagree with each other. It decides whether `quote` and `transcript_segments[].text` carry the prefix. Unverified.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: No state sits between a finished summarize and the persist stage.
  evidence: The stage completes into `summarizing`, matching Persist's own Txn A. The 720s stale sweep for `summarizing` could then flag a meeting that is waiting for persist dispatch. Unverified until real dispatch exists.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: Resume from `summarization_failed` has no code path.
  evidence: `auricle run` is a stub and `CrashRecovery` does not reconcile `summarization_failed`. The stage itself re-runs cleanly because `transcript.json` is immutable.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: `cost_usd` records only the answering call; a failed primary call's cost is lost when the fallback wins.
  evidence: A thrown `SummarizerError` carries no cost, and `Outcome.summary.cost` is the winner's.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: `telemetry.grounding_method` has no column, though Decision 4.5 and the Story 3.7 AC list it as a telemetry field.
  evidence: architecture.md:1533 says the `telemetry` table carries `grounding_method`, but no migration or `State.Telemetry` field defines it. The stage records it only in the `stage_events` completion metadata (`SummarizeMeta.grounding_method`). Adding the column is a migration, which this story's intent excludes.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-close-out-telemetry-blockquote-cross-stage-test.md`
  summary: architecture.md's telemetry DDL and write-authority matrix do not list `grounding_method`, and its DDL lacks the `summarization_prompt_set_hash` column position that the shipped schema will now use.
  evidence: `grounding_method` appears only in prose (architecture.md:1238, :1533) and the Story 3.7 AC. This story adds the column from that prose (TEXT holding `citations` or `substring`); the planning doc should be updated to match, but planning docs are outside a build run's edits.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-close-out-telemetry-blockquote-cross-stage-test.md`
  summary: A live end-to-end run of `__internal-stage summarize` with a real meeting row and a real Claude call has still not been done.
  evidence: It needs the maintainer's API key, spends real money, and needs a meeting the pipeline produced. This story verifies the same path with stub strategies, a production-configured store, and the eval fixtures; the maintainer's Story 3.8 comparison run is the first live check.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-close-out-telemetry-blockquote-cross-stage-test.md`
  summary: An item's `text` containing a line break breaks the vault note's bullet.
  evidence: `FrontmatterRenderer` renders `"- \($0.text)\n..."` assuming one line, and `text` is model output. This is the same class of bug the multi-line quote fix addressed for `quote`, but the change here does not touch `text`, so it predates this story. The fix is to normalize `text` to one line where the summary artifact is built or rendered.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-close-out-telemetry-blockquote-cross-stage-test.md`
  summary: epics.md:955 and :1128 (Story 1.4) say `summarization_prompt_set_hash` exists from migration #1 and that no later epic needs a column-adding migration.
  evidence: Migration #1 never declared the column, and this story adds it (with `grounding_method`) in migration #4. The planning text is stale; planning documents are outside a build run's edits.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-1-summarizerinterface-protocol-normalized-summarywithgrounding-output.md`
  summary: `Sources/Core/Errors.swift`'s top-of-file comment and `PersistError`'s doc comment still say `Persist` is a placeholder with no real implementation.
  evidence: `Sources/Persist/` holds shipped code since Epic 2 (`PersistStage`, `FrontmatterRenderer`, `VaultWriter`). Lines 8-11 and 28-31 of `Errors.swift` still carry the claim. It predates Story 3.1 and was found by the review pass. Severity low, location `Sources/Core/Errors.swift:8-11,28-31`.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-5-claudecitationssummarizer-citationgroundingvalidator-canonicalization-invariant-tests.md`
  summary: Near-identical private `URLProtocol` stub classes repeat across test targets with no shared `TestSupport` helper.
  evidence: Story 3.5 counted four (`AnthropicHTTPClientTests`, `ClaudeSubstringSummarizerTests`, `ClaudeCitationsSummarizerTests`, `CrossModeFixtureTests`). Stories 3.9 and 3.10 added `Tests/SummarizeTests/EvalStubResponses.swift` and `Tests/GoogleCalendarSourceTests/GoogleStub.swift`, so six files now declare a stub. Whether the two newer stubs duplicate the older four was not checked. Severity low.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-9-eval-harness-frozen-transcripts-regression-tests.md`
  summary: Tie the eval harness's default-wiring arm to the real composition root once Story 3.8 locks the default.
  evidence: `EvalDefaultWiring` in `Tests/SummarizeTests/SummarizeEvalHarnessTests.swift` hard-coded Citations primary with a substring fallback, mirroring the provisional wiring in `App/auricle-cli/Verbs/InternalStageWorker.swift`. `App/` has no test target, so nothing checked the two agreed. Story 3.8 locked substring with no fallback and the harness kept the old composition; the Epic 3 retro found it (VG-1). Severity low when logged, major once the default flipped.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-10-google-calendar-source-oauth-pkce-event-matcher.md`
  summary: A loopback listener stuck in `.waiting` would hang `authorize()` outside `redirectTimeout`.
  evidence: `LoopbackRedirectListener.start()` awaits only `.ready`, `.failed` or `.cancelled`, `handle(state:)` ignores `.waiting`, and `GoogleOAuthFlow.awaitRedirect` applies the timeout only after `start()` returns. Whether `NWListener` on `127.0.0.1` with an ephemeral port ever reports `.waiting` and never resolves is unverified. It settles by running `authorize()` where the listener cannot bind and observing which state arrives. Location `Sources/GoogleCalendarSource/LoopbackRedirectListener.swift` (`handle(state:)`). Severity medium (unverified).

- source_spec: `_bmad-output/implementation-artifacts/spec-3-12-vaultglossarybuilder-glossaryinjector-jargoncorrectionstrategy.md`
  summary: Pass `--vault-path` (and the meetings subdirectory) to the summarize worker from GUI dispatch once a config layer supplies `vault_path`.
  evidence: `SubprocessDispatcher.makeProcess` built `__internal-stage <stage> <id> --worker-protocol-version N` only, so a dispatched summarize run got an empty glossary and the wedge measurement read 0 eligible corrections. `Core/Config` did not exist. Location `Sources/Orchestrator/SubprocessDispatcher.swift`. Severity medium.

- closes: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`, "Record `summarization_prompt_set_hash` in telemetry"
  resolution: The stage writes `summarizationPromptSetHash` from the per-mode hashes it resolves before the paid call (`Sources/Summarize/SummarizeStage.swift`, `resolvePromptSetHashes` and the telemetry write). Migration #4 added the column.

- closes: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`, "`telemetry.grounding_method` has no column"
  resolution: Migration #4 (`Sources/State/Migrations/Migration004_TelemetryGroundingAndPromptSetHash.swift`) adds `grounding_method` and `State.Telemetry.groundingMethod` carries it.

- closes: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`, "A multi-line `quote` renders as a broken blockquote in the vault note"
  resolution: `FrontmatterRenderer.renderBlockquote` prefixes every line of the quote with `>`.

- closes: `_bmad-output/implementation-artifacts/spec-3-8-smoke-test-rig-scaffold.md`, "Assemble >=5 real meeting transcripts"
  resolution: Superseded. The maintainer accepted six public fixtures in `Tests/SummarizeTests/Fixtures/eval/` as the comparison set (Epic 3 retro SR-4). Validation on the maintainer's own recordings moves to Epic 4.

- closes: `_bmad-output/implementation-artifacts/spec-3-8-smoke-test-rig-scaffold.md`, "Wire `SummarizerOrchestrator(primary:fallback:)` in the composition roots"
  resolution: `auricle-cli` wires `SummarizerOrchestrator(primary: ClaudeSubstringSummarizer())` with no fallback. `AuricleApp` has no summarize path until Epic 4 or 6 (Epic 3 retro SR-5).

- source_spec: `_bmad-output/implementation-artifacts/spec-3-8-strategy-comparison-rig-scaffold.md`
  summary: Spot-check the hand scores (recall, false-keeps, quote quality) in `Tests/fixtures/strategy-comparison-results.md`.
  evidence: The comparison ran and its outcome is recorded, so the entry "Score recall, precision (false-keeps) and quote quality per transcript by hand" is answered in substance. The results file says the maintainer has not spot-checked the recall and false-keep scores. The default flip rests on the computed metrics (Citations returned no items on 5 of 6 transcripts), not on the hand scores (Epic 3 retro SR-6).

- closes: `_bmad-output/implementation-artifacts/spec-3-9-eval-harness-frozen-transcripts-regression-tests.md`, "Tie the eval harness's default-wiring arm to the real composition root"
  resolution: `Sources/ClaudeSummarizer/ShippedSummarization.swift` holds the shipped orchestrator. `InternalStageWorker` and the eval harness both build it, and a test fails if the definition gains a fallback. `SummarizerConfig()` is still built separately in the worker and the harness. Nothing checks that the worker itself calls the factory, because `App/` has no test target.

- closes: `_bmad-output/implementation-artifacts/spec-3-12-vaultglossarybuilder-glossaryinjector-jargoncorrectionstrategy.md`, "Pass `--vault-path` (and the meetings subdirectory) to the summarize worker"
  resolution: `SubprocessDispatcher.makeProcess` appends `--vault-path` from `Core/Config` (`vault_path` in `~/.auricle/config.toml`). `meetings_subdir` is read by `Config` but not passed, because the summarize worker does not use it. No default `vault_path` exists, so an unset key still gives an empty glossary.

- closes: `_bmad-output/implementation-artifacts/1-2-core-primitives-atomicwriter-ids-canonicaltranscript-dialects-config.md`, "Implement `Core/Config.swift`"
  resolution: `Sources/Core/Config.swift` loads `~/.auricle/config.toml` with an injectable location. It covers `vault_path`, `meetings_subdir` and the Google Calendar client keys only. The other FR58 keys are not read yet, and symlink normalization is not done.

- closes: `_bmad-output/implementation-artifacts/1-2-core-primitives-atomicwriter-ids-canonicaltranscript-dialects-config.md`, "Implement `CanonicalTranscript`"
  resolution: `Sources/Core/CanonicalTranscript.swift` landed with Story 3.1.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: Confirm that the real transcribe stage writes utterance ranges that include the `Speaker_N: ` prefix.
  evidence: The earlier entry "Whether an utterance's `[start,end)` range includes the `<Speaker_N>: ` prefix is undefined" is decided: ranges include the prefix (doc comment on `CanonicalTranscript.Utterance.start`, and the Story 4.1 acceptance criterion in `epics.md`). `SummaryArtifactMapper` strips one leading label and leaves a range without one unchanged, so a note prints each label once either way. Story 4.1 still has to write ranges that way; nothing has produced a real transcript yet.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-4-claudesubstringsummarizer-substringgroundingvalidator.md`
  summary: Raise `max_tokens` or stream for `xhigh` and `max` effort.
  evidence: `ClaudeSubstringSummarizer` sends `max_tokens` 16384. The API documentation recommends about 64k at `xhigh` and `max`, so those levels can end as `summarizer_response_truncated` on a long transcript. Found while mapping the effort level to the request.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`
  summary: The `StageRunner` completion write can still fail after a paid call and mark the meeting `summarization_failed`.
  evidence: The summarize stage's own post-write bookkeeping (telemetry, meeting row) no longer fails the stage. The completion write inside `StageRunner.run` is outside the stage's control. A retry pays again. Found while fixing RV-3 of the Epic 3 retro.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-6-summarizerorchestrator-primary-fallback-wiring.md`
  summary: A fallback outcome carries only the answering strategy's cost.
  evidence: Already recorded against Story 3.7. Restated here because the cost-ceiling check compares the answering call's cost to the ceiling, so a failed primary call's spend is invisible to it. No fallback is wired today.

- source_spec: `_bmad-output/implementation-artifacts/spec-3-10-google-calendar-source-oauth-pkce-event-matcher.md`
  summary: Nothing signs the maintainer in to Google, so a wired calendar source stays degraded.
  evidence: `InternalStageWorker` builds `GoogleCalendarSource.headless(...)` when `google_calendar.client_id` is set. Its browser opener throws, so an unauthorized run degrades to `needs-calendar-enrichment` instead of hanging. The only planned sign-in trigger is the Story 9.1 Settings button. Whether a Keychain prompt appears inside the headless worker (RV-4) and whether the `fields` mask and the `eventType` and `transparency` values match the real Calendar API are untested.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-frontmatterrenderer-data-to-markdown-with-all-schema-variants.md`
  summary: The rendered `date` frontmatter field is an unquoted plain YAML scalar, which a YAML-1.1 reader may implicitly resolve to a timestamp type rather than a string.
  evidence: Decision 2.2's literal schema example (`architecture.md:858`) mandates this exact unquoted shape, and `FrontmatterRenderer` reproduces it, so the risk comes from the architecture decision, not from the renderer. It settles by checking whether Story 2.5's migration-aware reader coerces the parsed `date` to `String` regardless of the YAML parser's scalar inference, or assumes `String` directly. Location `Sources/Persist/FrontmatterRenderer.swift:33`. Severity medium (unverified).

- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-frontmatterrenderer-data-to-markdown-with-all-schema-variants.md`
  summary: `FrontmatterRenderer` has no input for the `auricle/needs-summary` conditional tag, which `epics.md` lists beside `auricle/needs-attribution` and `auricle/needs-calendar-enrichment`.
  evidence: A search of `Sources/`, `App/` and `Tests/` finds no `needsSummary`, `needs-summary` or `needs_summary`, and `MeetingForFrontmatter` has no such field. Story 2.1's acceptance criteria list the tag (`epics.md:1151`), but Decision 2.2's variant table (`architecture.md:886-894`) and the same story's test sentence (`epics.md:1173`) cover only the attribution and calendar variants. Story 4.7 requires the tag on `published_partial` (`epics.md:2081`; Decision 4.1 defines that state at `architecture.md:1031`), and no story owns the renderer change. Open question: whether the renderer only adds the tag, or also omits the action-items and decisions sections instead of rendering them empty, as Decision 4.1 allows. Location `Sources/Persist/FrontmatterRenderer.swift` (tag selection) and `Sources/Persist/MeetingForFrontmatter.swift`. Severity medium.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-1-frontmatterrenderer-data-to-markdown-with-all-schema-variants.md`
  summary: Emoji and other code points above U+FFFF in a title are written as `\U0001F389`-style escapes, because libyaml cannot emit them.
  evidence: libyaml's printable-character check accepts at most three-byte UTF-8 sequences, so `allowUnicode: true` (`Sources/Persist/FrontmatterRenderer.swift:51`) still escapes supplementary-plane code points, while Basic Multilingual Plane characters (accented letters, CJK, em dash) print literally. Checked by rendering the title `🎉 Launch é 北京 —`, which produced `title: "\U0001F389 Launch é 北京 —"`. YAML readers decode the escape, so the value round-trips and only the raw file text is harder to read. No test in `Tests/PersistTests/FrontmatterRendererTests.swift` renders a supplementary-plane character. Location `Sources/Persist/FrontmatterRenderer.swift`. Severity low.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-2-filenameresolver-slug-priority-chain-normalization-and-edge-cases.md`
  summary: Characters with no NFKD compatibility decomposition to ASCII (German ß, ligatures like æ/œ) silently vanish during slug normalization the same way CJK and emoji do, rather than transliterating to an ASCII equivalent (e.g. ß -> ss).
  evidence: Not caused by this diff: Decision 2.4 (`architecture.md:924-988`) explicitly mandates NFKD compatibility decomposition as the normalization algorithm, and this story correctly implements exactly that. NFKD's decomposition table has no mapping for ß/æ/œ to ASCII (unlike accented Latin letters, which decompose into base + combining mark). This is an inherent consequence of the architecturally-chosen algorithm, not a defect introduced here. What would settle it: whether a future revision of Decision 2.4 wants a supplementary transliteration table for these specific characters, weighed against the added complexity for a narrow set of European-language titles. Location `Sources/Persist/FilenameResolver.swift` (`normalize`). Severity low (unverified) -- narrow character set, graceful fallthrough to the next slug source rather than a crash or corrupted output.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-2-filenameresolver-slug-priority-chain-normalization-and-edge-cases.md`
  summary: Non-ASCII punctuation with no NFKD decomposition to ASCII -- en dashes, em dashes, and similar -- is deleted rather than treated as a word separator, silently merging the words on either side (e.g. "Q3-Q4 Planning" with an en dash normalizes to "q3q4-planning", not "q3-q4-planning").
  evidence: Not caused by this diff, for the same reason as the ß/æ/œ item above: Decision 2.4 mandates "strip all non-ASCII characters" as a fixed pipeline step, with no separator-aware exception for punctuation. Verified directly: an en dash and an em dash both have no NFKD compatibility decomposition (they aren't accented-letter-shaped), so they fall to the strip step exactly like CJK or emoji, but unlike those, the ASCII text on both sides survives and now runs together. This is plausibly a more common real-world trigger than ß/æ/œ, since dashes are routine in calendar-app-generated titles. What would settle it: whether a future revision of Decision 2.4 wants the strip step to special-case dash-family punctuation (treat as a separator, like whitespace) ahead of the general non-ASCII strip. Location `Sources/Persist/FilenameResolver.swift` (`normalize`). Severity low (unverified) -- degrades slug readability for affected titles, never crashes or produces an invalid filename.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-3-vaultwriter-atomic-write-path-resolution-collision-handling.md`
  summary: Two related TOCTOU (time-of-check-to-time-of-use) races exist in `VaultWriter`, both requiring an external actor to change filesystem state in a narrow window between a check and a later use: (1) between the collision-detection existence check and `AtomicWriter`'s own `rename(2)` call, a different process could create a file at the exact resolved target path, which `rename` would then silently overwrite; (2) between `vaultPath`'s own validation and the later (intermediate-directory-creating) `meetingsSubdir` auto-creation call, `vaultPath` could in principle be deleted, causing that call to silently recreate it with default rather than inherited permissions -- violating the "never auto-create `vaultPath`" invariant.
  evidence: Both real, but not fixable within Story 2.3's scope without a disproportionate cost. (1) `AtomicWriter`'s own doc comment already states callers are responsible for serializing writes to a given path -- it does not offer collision-safe (exclusive-create) semantics, and adding them would mean either modifying `AtomicWriter` (an already-shipped, already-tested Story 1.2 primitive, out of scope there) or building new cross-process serialization machinery no architecture document currently specifies. (2) Review iteration 1 tried closing this one by disabling intermediate-directory creation for `meetingsSubdir` entirely, but that broke a real, documented configuration shape -- Decision 2.5's own rationale text gives `inbox/Meetings/` as an example `meetings_subdir` value, a nested path that needs multiple intermediate directories created. Iteration 2 reverted that fix in favor of accepting the underlying race, since supporting the documented nested-subdir case is more valuable than closing an even-narrower slice of an already-narrow window. Both races require two independent, near-simultaneous events (this call, plus some other actor deleting/creating the exact path in question at the exact right microsecond) -- the same "low-probability, manually recoverable" class of trade-off Decision 2.4 already explicitly accepts for cross-Mac filename collisions. What would settle it: whether a future story gives `AtomicWriter` (or a sibling primitive) an exclusive-create write mode (e.g. macOS's `renamex_np(RENAME_EXCL)` where available), which would close race (1); race (2) would need `VaultWriter` to walk and create `meetingsSubdir`'s path components one at a time rather than passing `withIntermediateDirectories: true`, verifying `vaultPath` itself is never the directory actually created. Location `Sources/Persist/VaultWriter.swift` (`collisionFreeTarget`, `resolveMeetingsSubdir`, `write`). Severity low (unverified) -- both require a narrow concurrent race; race (1) degrades to a silently and permanently overwritten colliding note (real data loss of that note's prior content, though not corruption of the write-in-progress itself), race (2) to a mis-permissioned auto-created `vaultPath` -- neither crashes or corrupts the write actually being performed.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-4-persist-stage-entry-point-compose-renderer-writer-re-publish-semantics.md`
  summary: A vault write that `meetings.vault_note_path` does not record makes the next publish write an ordinal-suffixed duplicate (`<date>-<slug>-2.md`) and leaves the first file orphaned.
  evidence: `PersistStage.publish` writes the note (`Sources/Persist/PersistStage.swift:134`), then sets `vaultNotePath` and calls `stateStore.updateMeeting` (`:136-137`) before `StageRunner`'s Txn B commits. Three triggers leave a file on disk with no row pointing at it. (1) A crash between the write and the `updateMeeting` call. (2) `updateMeeting` throws after a successful write: `run` catches the error and returns `.failed(targetState: .persistFailed, ...)` (`:92-98`), and the row keeps its old path. (3) A bare resume (`isRepublish` false) follows a failed re-publish: `writeNote` takes the rerun path only when `isRepublish` is true and the recorded file exists (`:149-151`), so the resume takes the standard path, finds the original at the base filename, and `VaultWriter.write` picks `-2`. No content is lost: the orphaned file is intact in the vault and the duplicate is a second copy. It matches the severity class of Story 2.3's collision-check-to-`rename` TOCTOU race. Location `Sources/Persist/PersistStage.swift:134-139` (`publish`) and `:92-98` (`run`). Severity low.

- source_spec: `_bmad-output/implementation-artifacts/spec-2-4-persist-stage-entry-point-compose-renderer-writer-re-publish-semantics.md`
  summary: `PersistStage.run` passes `activeState: .summarizing`, so crash recovery and the stale sweep treat a stuck or crashed persist run as a summarize run.
  evidence: `PipelineState` has no persisting active state, so `PersistStage.run` (`Sources/Persist/PersistStage.swift:83`) uses `.summarizing`, as Story 2.4's acceptance criteria specify, and `ActiveStageInFlight.stage(for: .summarizing)` returns `.summarize` (`Sources/Orchestrator/ActiveStageInFlight.swift:15`). Two consequences. (1) `CrashRecovery` lists `.summarizing` as reconcilable (`CrashRecovery.swift:24`) and re-dispatches whatever stage `ActiveStageInFlight` returns (`:68-76`), so a persist crash re-dispatches `.summarize` and re-runs a paid summarize, and persist itself is not re-dispatched. (2) The `.summarizing` case of `staleTransition` in `Sources/Orchestrator/StageRunner.swift` moves a meeting stuck past the 720s budget to `summarization_failed` with `stale_active_state`, not to `persist_failed`. This has the same root as the entry "No state sits between a finished summarize and the persist stage", which covers the other half: a finished summarize also leaves the meeting in `summarizing`. Closing both needs a distinct persisting state in `PipelineState` and a matching `ActiveStageInFlight` row. Location `Sources/Persist/PersistStage.swift:83`, `Sources/Orchestrator/ActiveStageInFlight.swift:15`, `Sources/Orchestrator/CrashRecovery.swift:24,68-76`, `Sources/Orchestrator/StageRunner.swift` (`staleTransition`). Severity medium.

- closes: `_bmad-output/implementation-artifacts/spec-2-1-frontmatterrenderer-data-to-markdown-with-all-schema-variants.md`, "The rendered `date` frontmatter field is an unquoted plain YAML scalar"
  resolution: `FrontmatterReader` composes YAML nodes with `Yams.compose` and reads fields through their literal-text accessors, not through tag-driven `Yams.load`, so no field resolves to a `Date` (`Sources/Persist/FrontmatterReader.swift:87-93`). `FrontmatterV1` also leaves `date` out, because no consumer needs it (`:20-26`). The renderer still writes the plain scalar.

- closes: `_bmad-output/implementation-artifacts/spec-3-7-summarize-stage-entry-point-cache-dir-handoff.md`, "No state sits between a finished summarize and the persist stage"
  resolution: `PipelineState.persisting` sits between them. `SummarizeStage` completes into `persisting`, `PersistStage` runs under it, and `StageRunner` gives it a fixed 60s stale budget that ends in `persist_failed`. `ActiveStageInFlight` maps it to `persist`, and `CrashRecovery` logs it without dispatching a subprocess, so neither the `summarizing` sweep nor the summarize re-dispatch can act on a meeting that is waiting for persist.

- closes: `_bmad-output/implementation-artifacts/spec-2-4-persist-stage-entry-point-compose-renderer-writer-re-publish-semantics.md`, "`PersistStage.run` passes `activeState: .summarizing`"
  resolution: `PersistStage.run` passes `activeState: .persisting`. `ActiveStageInFlight` maps that state to `persist`, the stale sweep ends it in `persist_failed`, and `CrashRecovery` logs it without dispatching a subprocess, so a crashed persist run is no longer read as a summarize run.

- closes: `_bmad-output/implementation-artifacts/spec-2-4-persist-stage-entry-point-compose-renderer-writer-re-publish-semantics.md`, "A vault write that `meetings.vault_note_path` does not record makes the next publish write"
  resolution: `PersistStage.run` no longer takes `isRepublish`. A run is a re-publish exactly when `vaultNotePath` names an existing file. Output identical to a file already in the vault is reused, not duplicated. `republish` writes nothing when the stored note already holds the rendering, `nextRerunTarget` reuses a re-run candidate with the same bytes, and `VaultWriter.write` returns an existing candidate with the same bytes instead of taking the next ordinal (`Sources/Persist/PersistStage.swift`, `Sources/Persist/VaultWriter.swift`). A note the user edited never matches, so it gets a re-run sibling. Known limit: a retry on a later day names a new re-run date, so it does not reuse an earlier day's orphaned re-run.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-4-sqlite-schema-statestore-and-grdb-migrations-with-full-telemetry-counter-columns.md`
  summary: The `schema_version` table is created by migration #1 but nothing ever inserts a row into it, despite its comment implying it is kept current.
  evidence: GRDB's `DatabaseMigrator` tracks applied migrations in its own `grdb_migrations` table, not this app-level table. No INSERT into `schema_version` exists and nothing reads it. The table and its comment are copied verbatim from architecture.md's Decision 2.1 SQL, which the story's frozen intent required be reproduced exactly. Location `Sources/State/Migrations/Migration001_Initial.swift`. Severity low. Logged from the Story 1.4 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-4-sqlite-schema-statestore-and-grdb-migrations-with-full-telemetry-counter-columns.md`
  summary: `meetings.duration_seconds`'s comment claims a `CHECK (>= 0)` constraint that does not exist in the DDL, so negative durations are silently accepted.
  evidence: The column is declared `duration_seconds INTEGER` with only a comment. No test inserts a negative value. Comment and column are copied verbatim from architecture.md's Decision 2.1 SQL ("Schema is exactly architecture.md:691-774's SQL" in the story's frozen intent). Settled by an architecture-level decision to add the constraint or strike the comment. Location `Sources/State/Migrations/Migration001_Initial.swift:36`. Severity medium. Logged from the Story 1.4 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-4-sqlite-schema-statestore-and-grdb-migrations-with-full-telemetry-counter-columns.md`
  summary: The terminal-state list `'verified','retention_expired','discarded'` is duplicated as independent raw strings in two places with no shared constant.
  evidence: `idx_meetings_state`'s partial-index predicate (migration SQL) and `StateStore.fetchPending()`'s filter list the same three states independently, so an edit to one desyncs them. `fetchPending()`'s doc comment cross-references the index by name. The migration side must stay frozen-verbatim per architecture.md. Best resolved when a story next adds a terminal state. Location `Sources/State/StateStore.swift`, `Sources/State/Migrations/Migration001_Initial.swift`. Severity low. Logged from the Story 1.4 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-4-sqlite-schema-statestore-and-grdb-migrations-with-full-telemetry-counter-columns.md`
  summary: `sprint-status.yaml`'s `1-4-...` entry still read `backlog` although the story was implemented.
  evidence: Same systemic gap the Story 1.2 entries describe: the workflow variant never referenced `sprint-status.yaml`, so syncing it was not fixable at the story level. Severity low. Logged from the Story 1.4 spec's `deferred` list (Epic 1 retro PL-3); `docs/loop-engineering-notes.md` documents it.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-5-orchestrator-stagerunner-crashrecovery-retentionscheduler-scaffold.md`
  summary: `StateStore.recordStageTransition`'s `meetings` UPDATE has no guard against the meeting's state having changed since it was last read, creating a race between the stale-detection sweep and a stage's own completion.
  evidence: The UPDATE was `UPDATE meetings SET state = ? WHERE id = ?`. The sweep reads a meeting through `fetchPending()` and writes its synthesized failure later, so a real Txn B landing in that window is overwritten by a failure. No production caller existed yet; Epic 3 and 4's stages were to be the first. Settled by optimistic-concurrency guarding before real stages call `StageRunner.run` concurrently. Location `Sources/State/StateStore.swift`, `Sources/Orchestrator/StageRunner.swift`. Severity medium. Logged from the Story 1.5 spec's `deferred` list (Epic 1 retro DR-1, PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-5-orchestrator-stagerunner-crashrecovery-retentionscheduler-scaffold.md`
  summary: `sprint-status.yaml`'s `1-4-...` and `1-5-...` entries both still read `backlog` although both stories were implemented and reviewed.
  evidence: Same recurring gap as the Story 1.4 entry above. Severity low. Logged from the Story 1.5 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-6-telemetry-recorder-stageeventlogger-and-stagemetadata.md`
  summary: `StageMetadata`'s Codable conformance wraps each case's payload under a case-name key, diverging from architecture.md's documented flat `metadata_json` shape.
  evidence: `encode(to:)` writes `{"transcribe": {...}}`, not the flat `{"model_id": ...}` Decision 4.5 illustrates. The wrapper solves a real constraint: `capture` and `attribute` have content-identical empty placeholder payloads, undecodable without a discriminator key. epics.md's AC requires only the snake_case dialect. The transcribe and persist stages already encode their `*Meta` types directly, unwrapped. Settled by whichever story builds the first generic consumer of the JSON. Location `Sources/Telemetry/StageMetadata.swift`. Severity low. Logged from the Story 1.6 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-6-telemetry-recorder-stageeventlogger-and-stagemetadata.md`
  summary: architecture.md's own `StageMetadata` Codable sketch lists only 6 cases, omitting `reviewDiarization`, although Decision 4.5 otherwise documents `reviewing_diarization` payloads.
  evidence: A pre-existing inconsistency in the planning document (the sketch is near line 1216), not caused by the story, which follows epics.md's 7-case AC. Location `architecture.md` (Decision 4.5). Severity low. Logged from the Story 1.6 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-6-telemetry-recorder-stageeventlogger-and-stagemetadata.md`
  summary: `sprint-status.yaml`'s Epic 1 entries (1-4, 1-5, 1-6) all still read `backlog` although all three stories were implemented and reviewed.
  evidence: Same recurring gap as the Story 1.4 entry above. Severity low. Logged from the Story 1.6 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-7-cli-executable-scaffold-auricle-binary-with-bare-status-hidden-internal-stage.md`
  summary: Ordinary swift-argument-parser usage errors (missing required argument, unparseable flag, a missing subcommand) exit with the library's own usage-error code, not Decision 1.5's "1 = user error."
  evidence: The framework owns its automatic parsing-failure path. Remapping it means re-implementing argument validation for every flag on every verb, and no AC asks for it. Observed by the Epic 1 retro: `auricle bogusverb` exits 64 and its usage text names the hidden `__bare-status` subcommand (BV-1). `WorkerExitCode.usage` names the 64 and a test pins that ArgumentParser reports it, so a change shows up; it does not remap it. Location all `App/auricle-cli/Verbs/*.swift`. Severity low. Logged from the Story 1.7 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-7-cli-executable-scaffold-auricle-binary-with-bare-status-hidden-internal-stage.md`
  summary: `BareInvocation`'s tie-break order is unspecified if two meetings ever shared the same active state (e.g. both `recording`).
  evidence: No tie-break rule existed in Decision 1.5 or the story's AC. Real but low-probability: normal capture leaves at most one meeting `recording`, so it surfaces after an unreconciled multi-meeting crash. Location `App/auricle-cli/Verbs/BareInvocation.swift`. Severity low. Logged from the Story 1.7 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-7-cli-executable-scaffold-auricle-binary-with-bare-status-hidden-internal-stage.md`
  summary: A meeting in an active state other than the 3 `BareInvocation` checks (e.g. `transcribing`, `summarizing`, a `*_failed` state) falls through to "Nothing in flight.", which is misleading once real stages exist.
  evidence: Was unreachable outside test fixtures when logged, and Decision 1.5's table specifies no message for these states. Real stages now run through `StageRunner`, so it is reachable (Epic 1 retro RV-4). Whichever story next touches `BareInvocation` should cover the full state set. Location `App/auricle-cli/Verbs/BareInvocation.swift`. Severity low. Logged from the Story 1.7 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-7-cli-executable-scaffold-auricle-binary-with-bare-status-hidden-internal-stage.md`
  summary: None of the 10 stub verbs' declared flags are asserted by an automated test to parse under their intended kebab-case names.
  evidence: Verified by hand that every flag parses, but a later typo surfaces only when a story reads the flag. Closing it needs test infrastructure for `App/auricle-cli`, which `swift test` does not cover. Location `App/auricle-cli/Verbs/*.swift`. Severity low. Logged from the Story 1.7 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-7-cli-executable-scaffold-auricle-binary-with-bare-status-hidden-internal-stage.md`
  summary: `App/Project.swift`'s bundle-embedding fix (`productName`, `copyFiles`) has no automated regression check.
  evidence: Reverting it would silently break every real subprocess dispatch while `swift test` stays green. Story 1.7 named Story 1.8 as owner, and Story 1.8's frontmatter says `deferred: []`; `scripts/check.sh` builds both schemes and asserts nothing about bundle contents (Epic 1 retro BV-2). Location `App/Project.swift`. Severity low. Logged from the Story 1.7 spec's `deferred` list (Epic 1 retro PL-3).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-7-cli-executable-scaffold-auricle-binary-with-bare-status-hidden-internal-stage.md`
  summary: `sprint-status.yaml`'s Epic 1 entries (1-4 through 1-7) all still read `backlog`.
  evidence: Same recurring gap as the Story 1.4 entry above. Severity low. Logged from the Story 1.7 spec's `deferred` list (Epic 1 retro PL-3).

- closes: `_bmad-output/implementation-artifacts/spec-1-4-sqlite-schema-statestore-and-grdb-migrations-with-full-telemetry-counter-columns.md`, "`sprint-status.yaml`'s `1-4-...` entry still read `backlog`"
  resolution: Repaired on 2026-09-18 (Epic 3 retro): `sprint-status.yaml` reads `done` for stories 1-4 through 1-8. `AGENTS.md` names each story's own spec frontmatter `status` as the ground truth, because the build workflow does not update this file.

- closes: `_bmad-output/implementation-artifacts/spec-1-5-orchestrator-stagerunner-crashrecovery-retentionscheduler-scaffold.md`, "`sprint-status.yaml`'s `1-4-...` and `1-5-...` entries both still read `backlog`"
  resolution: Same repair as the Story 1.4 entry: `sprint-status.yaml` reads `done` for stories 1-4 and 1-5.

- closes: `_bmad-output/implementation-artifacts/spec-1-6-telemetry-recorder-stageeventlogger-and-stagemetadata.md`, "`sprint-status.yaml`'s Epic 1 entries (1-4, 1-5, 1-6)"
  resolution: Same repair as the Story 1.4 entry: `sprint-status.yaml` reads `done` for stories 1-4 through 1-6.

- closes: `_bmad-output/implementation-artifacts/spec-1-7-cli-executable-scaffold-auricle-binary-with-bare-status-hidden-internal-stage.md`, "`sprint-status.yaml`'s Epic 1 entries (1-4 through 1-7)"
  resolution: Same repair as the Story 1.4 entry: `sprint-status.yaml` reads `done` for stories 1-4 through 1-7.

- closes: `_bmad-output/implementation-artifacts/spec-1-5-orchestrator-stagerunner-crashrecovery-retentionscheduler-scaffold.md`, "`StateStore.recordStageTransition`'s `meetings` UPDATE has no guard"
  resolution: `StateStore.recordStageTransition` takes `expectedState` and `expectedUpdatedAt` and adds them to the UPDATE's `WHERE`. A write that finds the row changed throws `StateStoreError.staleWrite` and lands nothing; `StageRunner.synthesizeFailure` always guards on the active state, and the sweep passes the `updated_at` it read. The `updated_at` guard is what catches a stage that completes into its own active state. `run`'s own two transactions stay unguarded by design, so a stage that finishes late still wins over a sweep failure. The whole-row `StateStore.updateMeeting` is deleted in favour of `setVaultNotePath` and `setCalendarMatch`. Tests: `StageRunnerStateGuardTests`, `StateStoreTests`.

- closes: `_bmad-output/implementation-artifacts/spec-1-3-log-facade-with-sensitivity-tagging-and-redaction.md`, "No test exercises the public `Log.debug/.info/.warn/.error` entry points with a `.sensitive` field"
  resolution: `Log` has an internal `init(category:sink:)` whose sink receives the level and the already-redacted message. `LogTests` drives `info`, `warn`, `error` (and `debug` in a debug build) with a `.sensitive` field and asserts the sink never receives the value. `StageRunner` takes the same `Log`, so its transition logging is tested the same way.

- closes: `_bmad-output/implementation-artifacts/spec-1-7-cli-executable-scaffold-auricle-binary-with-bare-status-hidden-internal-stage.md`, "`BareInvocation`'s tie-break order is unspecified"
  resolution: `BareInvocationResolver` picks the newest meeting per state by reference timestamp, ties by the larger id, for `recording` as for the two `awaiting` states, and the hints name that meeting's id (`Sources/Core/BareInvocationStatus.swift`, `BareInvocationResolverTests`).

- closes: `_bmad-output/implementation-artifacts/spec-2-1-frontmatterrenderer-data-to-markdown-with-all-schema-variants.md`, "Emoji and other code points above U+FFFF in a title are written as `\U0001F389`-style escapes"
  resolution: Accepted as a libyaml limit, and now tested. `aTitleWithCodePointsAboveTheBasicMultilingualPlaneRoundTripsAsAYAMLValue` (`Tests/PersistTests/FrontmatterRoundTripTests.swift`) renders `🎉 Launch é 北京` and asserts the parsed YAML value equals the input. The raw file text differs from the input and the value does not. The renderer is unchanged.

- closes: `_bmad-output/implementation-artifacts/spec-2-1-frontmatterrenderer-data-to-markdown-with-all-schema-variants.md`, "`FrontmatterRenderer` has no input for the `auricle/needs-summary` conditional tag"
  resolution: The ownership and behavior questions are answered. Story 4.7 owns the renderer change (`epics.md`, the `published_partial` criterion), and a `published_partial` note omits the Action Items and Decisions sections entirely (`architecture.md`, Decision 4.1). The renderer input itself is not built yet and is Story 4.7's work.

- source_spec: `_bmad-output/implementation-artifacts/epic-2-retro-2026-09-18.md`
  summary: Nothing specifies where persist gets its input for a `published_partial` note when summarize failed and no `summary.json` exists.
  evidence: `PersistStage.readSummaryArtifact` throws `summaryArtifactUnreadable` when `summary.json` is missing (`Sources/Persist/PersistStage.swift`). A `published_partial` note exists exactly when summarize produced no usable output (`architecture.md`, Decision 4.1), so the stage cannot publish it as built. Two options: summarize writes an empty stub artifact on failure, as the reviewing stage does for a timeout, or persist renders from the transcript and attribution when the artifact is absent. Story 4.7 must settle this before it is built. Severity medium.

- source_spec: `_bmad-output/implementation-artifacts/epic-2-retro-2026-09-18.md`
  summary: A re-run ignores the configured `vault_path` and `meetings_subdir`, and a note the user renamed or moved in Obsidian falls back to a fresh publish with no `supersedes`.
  evidence: The re-publish path takes its directory from the stored `vault_note_path` and writes through `VaultWriter.writeExact`, which skips vault validation (`Sources/Persist/PersistStage.swift` `republish`, `Sources/Persist/VaultWriter.swift`). A `vault_path` or `meetings_subdir` change after the first publish sends re-runs to the old folder. A stored path that no longer exists is treated as a deleted original, so a renamed note gets a second note with the same `meeting_id` and no lineage link. Finding by `meeting_id` with `FrontmatterReader` is one option. Severity low.

- source_spec: `_bmad-output/implementation-artifacts/epic-2-retro-2026-09-18.md`
  summary: The note date and the `meeting-at-<HHMM>` slug use the time zone at persist time, and no capture-time zone is stored.
  evidence: `PersistStage.localDateAndTime` formats the capture instant in the injected zone, which defaults to `TimeZone.current` (`Sources/Persist/PersistStage.swift`). `MeetingForFilename` and `epics.md` (Story 2.2) say "local time at capture". No column in `Sources/State` stores a zone, so a capture before travel, or a retried persist in another zone, can shift the date by a day and disagree with the summarizer's `Meeting at ... <zone>` title. The zone is now injectable, so a stored zone can be passed in without a signature change. Severity low.

- source_spec: `_bmad-output/implementation-artifacts/epic-2-retro-2026-09-18.md`
  summary: Task cancellation inside persist is recorded as a terminal `persist_failed` instead of leaving the meeting for crash recovery.
  evidence: The blanket `catch` in `PersistStage.run` also catches `CancellationError` and returns `.failed(targetState: .persistFailed, errorClass: "persist_unexpected_error")`. `StageRunner.run` leaves a meeting in its active state only when `work` throws. This follows Story 2.4's rule that nothing propagates past `work`. Decide once Story 4.7's SIGINT handling exists. Severity low.

- source_spec: `_bmad-output/implementation-artifacts/epic-2-retro-2026-09-18.md`
  summary: Small `FilenameResolver` edge cases.
  evidence: `truncate` drops the last word that fits when the character after the cap is a hyphen. `attendeeSlug` gives `with-ben-and-ben` for a duplicate attendee, matches `selfWikilink` by exact case although Obsidian links are case-insensitive, and normalizes alias and path syntax (`[[Ben Smith|Ben]]`) as plain text. The `meeting-at-` slug interpolates `captureTime24h` without normalizing it, which is safe only because its one caller formats it numerically (`Sources/Persist/FilenameResolver.swift`). Severity low.

- source_spec: `_bmad-output/implementation-artifacts/epic-2-retro-2026-09-18.md`
  summary: `FrontmatterReader` rejects input an editor can produce.
  evidence: A note with no frontmatter throws `malformedFrontmatter`, not `notAnAuricleNote` (`extractFrontmatterYAML`), and a non-integer `schema_version` throws `notAnAuricleNote` (`read`). A UTF-8 BOM or trailing space on a fence line fails. An empty `attendees:` or `supersedes:` key fails or decodes as `""` (`decodeAttendees`, `decodeSupersedes`). The last two are unverified: whether Obsidian writes an empty key was not checked. `epics.md` says a missing `schema_version` is "not an auricle note". Severity low.

- source_spec: `_bmad-output/implementation-artifacts/epic-2-retro-2026-09-18.md`
  summary: `FrontmatterRenderer.render` calls `fatalError` if Yams fails, while `PersistStage` refuses `fatalError` on a comparable path.
  evidence: `Sources/Persist/FrontmatterRenderer.swift` calls `fatalError` for a failure the code argues cannot happen. `PersistStage.encodeMetadataJSON` falls back to a literal instead and says why. No input that reaches the renderer is known to make Yams fail. Severity low.

- source_spec: `_bmad-output/implementation-artifacts/epic-2-retro-2026-09-18.md`
  summary: `SummaryArtifact` has no `meeting_id` or version field and does not declare `Sendable`, and the schema version is written in three places.
  evidence: `Sources/Core/SummaryArtifact.swift` decodes whatever `summary.json` holds, with no check that it belongs to the meeting. The frontmatter schema version is `PersistStage.frontmatterSchemaVersion`, the renderer's caller-supplied `schemaVersion`, and `FrontmatterReader`'s two bounds, so a writer bump without a reader bump would make the app's own reader reject its notes as too new. One shared constant, or a test that reads back a note rendered with `PersistStage`'s version, would prevent it. Severity low.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-5-orchestrator-stagerunner-crashrecovery-retentionscheduler-scaffold.md`
  summary: `RetentionScheduler` re-fires its handler for every due `pending` timer on every pass, because nothing marks a timer processed.
  evidence: `StateStore.fetchDueRetentionTimers` returns every row with `status = 'pending'` and `fires_at <= asOf`, and no `StateStore` writer moves a row to `fired`. `RetentionSchedulerTests` says so in a comment ("nothing in this scaffold marks a row processed"). Story 8.5's acceptance criteria mark the row `fired` after the action and cover the error case, but do not say the scheduler claims the row before it calls the handler, so a slow handler or a second pass can act twice. The missing clause belongs in Story 8.5. Location `Sources/Orchestrator/RetentionScheduler.swift`, `Sources/State/StateStore.swift`. Severity low. Logged from the Epic 1 retro (DR-10).

- source_spec: `_bmad-output/implementation-artifacts/spec-1-4-sqlite-schema-statestore-and-grdb-migrations-with-full-telemetry-counter-columns.md`
  summary: Timestamp precision is mixed, so two `stage_events` written inside one second have no defined order.
  evidence: The `meetings_updated_at` trigger stamps `%Y-%m-%dT%H:%M:%fZ` (milliseconds), while application code writes whole seconds through `ISO8601UTC`. `StateStore.fetchStageEvents` orders by `occurred_at` alone, with no `id` tiebreak, so a `started` and a `completed` event in the same second come back in an undefined order. `ISO8601UTC.date(from:)` reads both forms. No SQL compares the two forms yet, so nothing is wrong today; the first query that does would be. Settled by ordering on `occurred_at, id`, and by choosing one precision when a story first compares them. Location `Sources/State/StateStore.swift`, `Sources/State/Migrations/Migration001_Initial.swift`. Severity low. Logged from the Epic 1 retro (DR-11).

- closes: `_bmad-output/implementation-artifacts/spec-1-4-sqlite-schema-statestore-and-grdb-migrations-with-full-telemetry-counter-columns.md`, "The terminal-state list `'verified','retention_expired','discarded'` is duplicated"
  resolution: `PipelineState.terminal` (`Sources/Core/PipelineState.swift`) holds the list, and `StateStore.fetchPending` builds its filter from it. The migration keeps its raw predicate because shipped migrations are never edited (AR-DATA-5). `idxMeetingsStatePredicateListsExactlyThePipelineStatesListedAsTerminal` (`Tests/StateTests/MigrationTests.swift`) reads the index SQL from `sqlite_master` and fails when its states differ from the constant, so a new terminal state needs a migration that recreates the index.

- source_spec: `_bmad-output/implementation-artifacts/spec-1-4-sqlite-schema-statestore-and-grdb-migrations-with-full-telemetry-counter-columns.md`
  summary: `StateStore.fetchStageEvents` orders ties on `occurred_at` by `id`. The mixed timestamp precision behind them is still open.
  evidence: The ordering is `occurred_at, id` (`Sources/State/StateStore.swift`), and `id` is `INTEGER PRIMARY KEY AUTOINCREMENT`, so it follows write order. This is the tiebreak half of the entry "Timestamp precision is mixed" (Epic 1 retro DR-11). That entry has no `closes:` because no story has chosen one precision. The tiebreak does not order a whole-second value against a millisecond value from the same second, because text order puts `.` before `Z` (`00.500Z` sorts before `00Z`). No `stage_events` writer stamps milliseconds today. `fetchStageEventsOrdersSameSecondEventsByID` (`Tests/StateTests/StateStoreTests.swift`) asserts the `ORDER BY` clause as well as the returned order, because SQLite already returns tied rows in rowid order and the result alone cannot fail without the tiebreak. Severity low.
