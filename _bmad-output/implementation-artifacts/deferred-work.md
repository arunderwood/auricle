# Deferred Work

Append-only. Each entry records a finding routed to `defer` during a review pass. Do not modify existing entries or look for duplicates.

- source_spec: `_bmad-output/implementation-artifacts/1-1-project-initialization-xcode-swiftpm-hybrid.md`
  summary: Story status vocabulary disagrees across tracking files — the story file's `Status` field uses bmad-build's enum (draft/ready-for-dev/in-progress/in-review/done) while `sprint-status.yaml` uses its own documented enum (backlog/ready-for-dev/in-progress/review/done); the same story state is now named `in-review` in one file and `review` in the other.
  evidence: Verified in both files. Each value is correct per its own file's schema comment, so this isn't a bug in either file — it's a structural mismatch between two coexisting BMAD tracking conventions in this repo, predating this story. Reconciling it means picking one canonical vocabulary or adding a mapping between the two skill families, which is outside any single story's scope.

- source_spec: `_bmad-output/implementation-artifacts/1-1-project-initialization-xcode-swiftpm-hybrid.md`
  summary: `NSUserNotificationsUsageDescription`'s effect on the macOS runtime permission prompt is asserted as fact in `AuricleApp.swift`'s comment and the Dev Agent Record, but was not independently confirmed against current Apple documentation or an on-device run.
  evidence: If the key does not actually gate the prompt text as claimed, UX-DR44's locked user-voice copy silently never displays to the user — a real UX regression (medium if true) but not one that breaks any build/test gate, so it wasn't caught here. Settled by: requesting notification authorization in a running build on macOS 14 and confirming the shown description text matches the locked copy.
