---
title: 'Story 4.12: Score the Item, Count the False Keeps'
type: 'bugfix'
created: '2026-09-20'
status: 'done'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Both Epic 4 scorers key recall on the reference quote, so a correct item the model supports with a different sentence of the same discussion scores zero, and neither counts a kept item that matches no expected item, leaving precision unmeasured across the whole gate.

**Approach:** Amend `Tests/regression/ami/score.py` so an expected item counts as recalled when its quote overlaps a note block quote **or** its `text` overlaps a kept item's text at a calibrated threshold, report `false_keeps` per meeting and for the set, and make `Tests/scripts/run-epic4-exit-criteria.sh` call that same matching rule instead of its own substring test.

## Boundaries & Constraints

**Always:** One implementation of the matching rule, in `score.py`; the exit script imports it. Matching stays inside a section heading. The existing quote test and `RECALL_OVERLAP = 0.5` are unchanged. Thresholds live in `Tests/regression/ami/thresholds.json`. `Tests/fixtures/epic4-exit-results.md` stays aggregates-only under opaque labels: no transcript text, no quotes, no titles.

**Never:** Do not re-run the pipeline or spend Anthropic credit; re-score the five notes the 2026-09-21T00:52Z run left in the scratch vault. Do not reimplement the scorer in the exit script or in Swift. Do not raise `min_item_recall`; Story 4.13 owns that. Do not add a false-keep gate to the exit script's pass/fail criteria, which epics.md Story 4.10 defines.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Same passage | Expected quote overlaps a note block quote at >= 0.5 | Expected item recalled; kept item is not a false keep | No error expected |
| Same item, different passage | Quote overlap < 0.5, item-text overlap >= `item_text_overlap` | Expected item recalled; kept item is not a false keep | No error expected |
| False keep | Kept item matches no expected item in its section by either test | Counted in `false_keeps` | No error expected |
| Expected item has no `text` | `text` absent or empty in an exit-run expected file | Text test contributes nothing; quote test alone decides | No error expected |
| Kept item with a short quote | Note block quote under 4 words | Quote test returns 0; text test may still match | No error expected |
| Set breaches precision | Total `false_keeps` > `max_false_keeps` | `score.py report` prints REGRESSION and exits 1 | Non-zero exit |

</intent-contract>

## Code Map

- `Tests/regression/ami/score.py` -- the scorer. `note_quotes()` (line 50) drops each bullet's own text and keeps only its block quote; `overlap()` (line 64) is the word-overlap measure, reusable for item text unchanged; `meeting()` computes `kept_items`, `ungrounded_quotes` and `recalled_items`; `report()` prints the table and checks thresholds. `meeting()` already loads `manifest.json` from `repo_root`, so it can load `thresholds.json` the same way.
- `Tests/regression/ami/thresholds.json` -- holds `max_wer`, `max_realtime_factor`, `max_cost_usd`, `min_item_recall: 0.35`. Gains `item_text_overlap` and `max_false_keeps`.
- `Tests/scripts/run-epic4-exit-criteria.sh` -- the live exit run. Its inline python heredoc (the `counts=$(python3 - ...)` block) parses the note, validates frontmatter, path shape and quote grounding, then matches by exact substring of a short fragment. `repo_root` is already in scope. The trailing aggregation heredoc computes the pass rate from a `$results` file of space-separated columns.
- `Tests/regression/ami/prepare-exit-fixtures.sh` -- builds the exit fixture directory from AMI. Writes `{"section", "quote"}` items, where `quote` is a fragment looked up in `exit-fragments.json`.
- `Tests/regression/ami/exit-fragments.json` -- the fragment table. Exists only because the exit script's substring test cannot survive the ASR/reference transcript mismatch. Overlap matching handles that mismatch by construction, so the table becomes dead once the exit script adopts the shared rule.
- `Tests/regression/ami/README.md` -- documents the fragment scheme (the "Epic 4 exit criteria" section) and calibrates `min_item_recall` against "recall runs 42%". Both statements become wrong.
- `Tests/fixtures/epic4-exit-results.md` -- the run record. Its "Why it failed" section asserts 42.1% for this run.
- `Tests/SummarizeTests/Fixtures/eval/ami-es200{2a,2b,3a,3b}/expected.json`, `Tests/regression/ami/reference/es2004a/expected.json` -- read-only. Every expected item already carries both `text` and `quote`. 19 expected items in total.
- `~/auricle-scratch-vault/Meetings/2026-09-20-meeting-at-1752{,-2,-3,-4,-5}.md` -- read-only. The five notes from the 2026-09-21T00:52Z run at `74a3d80c790a3d89548017f545c7ec165a4373fa`, in AMI id order ES2002a, ES2002b, ES2003a, ES2003b, ES2004a; 4, 4, 1, 6 and 0 kept items, 15 in total.
- `Sources/Persist/FrontmatterRenderer.swift:100-119` -- read-only. `renderQuotedItemSection` emits `- <text>` then `  > ` per quote line, so a bullet's text is one line and the parser can take `line[2:]`.

## Tasks & Acceptance

**Execution:**
- `Tests/regression/ami/score.py` -- replace `note_quotes` with `note_items` returning each bullet's `text` and `quote`; add `matches(expected, kept, item_text_overlap)` applying the two tests; load `thresholds.json` in `meeting()`; emit `false_keeps`; print false keeps per meeting and for the set in `report()` and breach on `max_false_keeps` -- one implementation of the rule, so the bench (Story 4.11) and the regression suite cannot drift.
- `Tests/regression/ami/thresholds.json` -- add `item_text_overlap: 0.55` and `max_false_keeps: 6` -- the calibration belongs beside the other limits, not inside the code.
- `Tests/scripts/run-epic4-exit-criteria.sh` -- import `score.py` from `repo_root` in the counting heredoc and match with `matches()`; keep the frontmatter, path-shape and grounding checks; print false keeps per fixture and in the summary -- the exit script and the regression suite stop disagreeing.
- `Tests/regression/ami/prepare-exit-fixtures.sh` -- emit the reference `quote` and `text` instead of a fragment; drop the `exit-fragments.json` lookup -- overlap matching removes the reason fragments existed.
- `Tests/regression/ami/exit-fragments.json` -- delete -- nothing reads it once the exit script matches by overlap.
- `Tests/regression/ami/README.md` -- rewrite the fragment paragraphs and the `min_item_recall` calibration paragraph for the two-test rule -- the README documents the rule it must now describe.
- `Tests/regression/ami/test_score.py` -- new; a dependency-free self-check of `note_items`, `matches` and the calibration window, run by `scripts/check.sh lint` -- `swift test` cannot reach Python, and the matching rule now carries a calibrated threshold that must not drift unobserved.
- `scripts/check.sh`, `AGENTS.md` -- run the scorer self-check in the lint phase and name it in the gate chain -- the gate is the one place a rule change gets caught.
- `Tests/fixtures/epic4-exit-results.md` -- add a "Re-score" section recording the 2026-09-21 run re-scored under the amended scorer: the corrected baseline, the re-scored recall, the false-keep count, the 8-item classification under opaque labels, and the 78.9% cap -- the record is the story's deliverable.

**Acceptance Criteria:**
- Given the five notes from the 2026-09-21T00:52Z run and the amended scorer, when they are re-scored, then item recall is 11/19 and total false keeps is 4.
- Given `score.py report` over a results file, when it runs, then it prints a false-keep count per meeting and for the set, and exits 1 when the set total exceeds `max_false_keeps`.
- Given `Tests/scripts/run-epic4-exit-criteria.sh` and `Tests/regression/ami/score.py`, when both decide whether an expected item survived, then they call the same function.
- Given `Tests/fixtures/epic4-exit-results.md`, when it is read, then the re-score is labelled as a re-score of the 2026-09-21 run rather than a new run, and it states that 15 items kept against 19 expected caps perfect alignment at 78.9%, below the 80% floor.
- Given `make check`, when it runs, then every phase passes.

## Design Notes

**Calibration of `item_text_overlap = 0.55`.** Every (expected, kept) pair in the 2026-09-21 run was hand-labelled same-item or not, then scored with `overlap()` on item text. The highest non-pair scores 0.526 (ES2002a's user-interface action item against the industrial-designer bullet, which share the boilerplate "will work on the ... before the next meeting"). The lowest same-item pair the quote test misses scores 0.583. 0.55 sits between them. The margin is about 0.03 on each side, measured over 15 kept items, so it is a tripwire calibrated on one run, not a law.

**`max_false_keeps = 6` against a baseline of 4.** `min_item_recall` is set below its baseline so ordinary variation does not trip it; `max_false_keeps` is set above its baseline for the same reason. One item is 6.7 percentage points of precision at this set size, so integer counts are coarse and a tight bound would be noise.

**The exit script prints false keeps but does not gate on them.** epics.md Story 4.10 defines the exit criteria as the pass rate and the cost ceiling. Adding a third gate would change the exit bar, which is not this story's job. `score.py report` enforces the limit; the exit script makes the number visible.

**Why `overlap()` is reused unchanged for item text.** It measures the share of the shorter side's words the longer side also holds, which is what a curated sentence and a model sentence about the same item look like. Its four-word minimum applies to the kept side and excludes nothing real: no item text in the fixture set is that short.

## Verification

**Commands:**
- `python3 Tests/regression/ami/test_score.py` -- expected: `test_score: 0 failed`, exit 0.
- `python3 Tests/regression/ami/score.py report Tests/regression/ami/thresholds.json <results>` -- expected: a table with a false-keep column and a set total.
- `bash -n Tests/scripts/run-epic4-exit-criteria.sh Tests/regression/ami/prepare-exit-fixtures.sh` -- expected: no syntax errors.
- `make check` -- expected: every phase passes.

**Manual checks (if no CLI):**
- Re-score the five scratch-vault notes with the amended `score.py` functions and confirm 11/19 recall and 4 false keeps.
- `grep -rn exit-fragments Tests/` returns nothing.

## Auto Run Result

Status: done

Re-scored the 2026-09-21T00:52Z run at `74a3d80c790a3d89548017f545c7ec165a4373fa` from the five notes it left in the scratch vault. No pipeline run, no Anthropic credit.

- Item recall 11/19 = 57.9%, up from 7/19 = 36.8% on the quote test alone. False keeps 4 of 15 kept items.
- The exit script and the regression suite return the same 11/19 over those notes; they returned 26.3% and 36.8% before.
- Of the 8 kept items the quote test missed: 4 are the same item supported by a different passage, 4 are false keeps.
- Correction to the prior record: 42.1% was never this run's number. It is the `history.jsonl` total, which mixes four meetings at revision `4e40120f` with one at `74a3d80c`.
- `make check` passes every phase.
