# Loop Engineering Notes

Working notes on using Claude Code's `/loop` skill plus the BMAD `bmad-build-auto`
workflow to drive hands-free implementation of backlog stories on this project.
Updated as the pattern gets used and refined — not a spec, just what's been learned.

## What this is

`/loop <prompt>` (no fixed interval) lets Claude self-pace a recurring task: run the
prompt, decide whether another iteration is warranted, schedule a wakeup or stop.
Paired with `bmad-build-auto` (spec → implement → verify → 4-layer review → patch →
finalize → commit, one backlog story per invocation), this gives a loop that can pull
several stories off a sprint backlog with only a stop/continue decision at each
boundary, instead of a prompt per story.

First real run: 2026-09-16, Epic 1 stories 1.4 through 1.7 (SQLite schema/StateStore,
Orchestrator scaffold, Telemetry, CLI executable scaffold), four iterations across one
session, three of them requested as separate manual continuations past the original cap.

## What worked

- **Fallback-heartbeat + task-notification pairing.** While a subagent worked on an
  implementation or a patch batch, scheduling a ~20–25 minute `ScheduleWakeup` as a pure
  fallback (never as the primary wake signal) meant zero wasted polling — every
  subagent's completion notification arrived well before the fallback would have fired.
- **Stop-on-blocked did its job.** Story 1.4's first commit attempt failed on 1Password
  SSH-signing requiring interactive unlock (unavailable in an unattended session). The
  loop stopped immediately rather than retrying blindly or silently bypassing signing,
  reported the exact blocking condition, and resumed cleanly once the maintainer
  unlocked 1Password and asked for a retry.
- **The story cap forced real check-ins.** Stopping after 3 stories (1.4–1.6) meant a
  human looked at the outcome before more work happened, rather than the loop silently
  consuming the whole epic.
- **The 4-layer review caught a real bug, not just style nits.** Story 1.5's review
  (Blind Hunter, Edge Case Hunter, Verification Gap Reviewer, Intent Alignment Auditor)
  found that `CrashRecovery` was about to re-dispatch the in-process `notify` stage as a
  subprocess — a genuine architectural violation that would have shipped invisibly since
  nothing exercises that path yet. Across all four stories: 1 high-severity finding, ~16
  medium, dozens of low, roughly a third rejected on direct verification (including two
  claims refuted with a throwaway scratch test rather than by assertion).
- **Independent re-verification, not just trusting the subagent's report.** Every story
  had its build/tests/manual checks re-run outside the implementing subagent before
  being accepted — this caught nothing dramatic in this run, but it's the difference
  between "the report says it passed" and "it actually passes."

## What needed tweaking

- **`sprint-status.yaml` drifted from day one and nothing in the loop caught it.** The
  `bmad-build-auto` workflow never touches that file — it only writes each story's own
  spec file's frontmatter `status`. The `/loop` prompt's own instruction to "check
  sprint-status.yaml for the lowest-numbered story still at backlog" was therefore
  checking a file that was already lying by story 1.5. Every iteration required a manual
  cross-check against the actual spec files. **Fix for next time:** point story-selection
  logic at the spec files' own `status` fields (or `git log`), not at `sprint-status.yaml`
  — and run `bmad-sprint-planning` (its "fix sprint status" / repair intent) as a
  separate step to resync the tracker, rather than trying to fold that into the
  implementation loop.
- **The cap has no "extend" mechanism.** Once 3 stories fired the stop condition,
  continuing meant asking again for each subsequent story by name (1.5, then 1.6, then
  1.7) rather than there being a way to say "raise the cap" and have the loop keep
  going. Fine for a handful of manual continuations; would get tedious for a long run.
  **Fix for next time:** state a cap that actually covers the intended chunk of work up
  front, sized to what's realistically left (e.g. "the rest of Epic 1" or an explicit
  number), rather than defaulting to a small cap and re-asking.
- **An unrelated command mid-loop is a real timing seam.** `/loop` reserves no floor
  while a background subagent is running; a `/ship` invoked mid-patch-cycle landed
  before that cycle finished. Handled correctly here (finish the in-flight story before
  shipping), but worth remembering that other requests can queue up behind a running
  loop rather than being blocked by it.
- **Stories that touch the Xcode/Tuist side (not pure SwiftPM) lose automated test
  coverage almost by default.** `App/auricle-cli` has no XCTest target, so anything
  implemented there (Story 1.7) shipped with zero `swift test`-visible regression
  protection until review explicitly called it out and the fix was to extract testable
  logic into a SwiftPM-visible module. Worth deciding up front, for any story touching
  `App/`, whether logic should be extracted into `Sources/` for testability rather than
  discovering the gap in review each time.

## Repairing `sprint-status.yaml`

**Why it drifts.** `bmad-build-auto` has no sprint-status step. It writes only the spec's
frontmatter `status`. Interactive `bmad-build` syncs `in-progress` and `review`, and
`bmad-code-review` is what moves a story to `done`. The spec is the truth; the tracker
falls behind.

**What it breaks.** `bmad-retrospective` reads the tracker, counts every finished story
as pending, and forces a rejected verdict. `bmad-help` recommends stories already built.

**When to repair.** Before `bmad-retrospective`, and before trusting `bmad-help` or the
sprint status view after a batch of stories. Not per story: an `on_complete` sync would
add a commit per story and touch `last_updated` on every branch.

**How.** Ask for `bmad-sprint-planning` "fix sprint status". It proposes a status per
story from the specs. Check that each `done` spec is a whole story, not a partial one,
then confirm. It rewrites the file with `sprint_plan.py generate --fresh --set`: long
story keys shorten to the script's 66-character slug cap, and `action_items` carry over.
Verify with `sprint_plan.py validate` (`valid: true`) and `bmad-retrospective`'s
`detect-epic --epic N` (empty `pending_stories`).

## Recommendations baked into future loop prompts

1. Name the actual stopping condition explicitly (a specific epic, a specific number of
   stories) rather than a small default that requires re-asking.
2. Have the loop determine "what's next" from spec-file status / git history, not from
   `sprint-status.yaml`.
3. Keep "stop immediately on blocked" — it's the load-bearing safety rail and it worked.
4. For any story touching `App/` (the Tuist/Xcode side), call out that new logic should
   land in a SwiftPM-visible module when it can be, so it's actually reachable by
   `swift test`.
