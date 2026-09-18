# Deferred Work

Append-only. Each entry records a finding routed to `defer` during a review pass. Do not modify existing entries or look for duplicates.

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
  summary: Thread real attendees and `--prompt-dir` into the prompt.
  evidence: Both strategies hard-code `attendees: []` and `promptDir: nil`; `SummarizerStrategy.summarize` and `SummarizerConfig` have no channel for either. Calendar attendees arrive with Stories 3.10/3.11.

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
