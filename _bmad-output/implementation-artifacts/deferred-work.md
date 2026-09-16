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
