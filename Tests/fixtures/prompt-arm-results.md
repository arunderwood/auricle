# Story 4.13: prompt arm results

Numbers only. The notes each run produced hold real meeting content from a
public corpus and are written to the gitignored
`Tests/fixtures/recall-bench-output/<timestamp>/`, never here.

Every arm is a `system.md` that overrides the bundled one; the prompt builder
falls back per file, so the substring addendum is the shipped one in every arm.
Arm directories are under `Tests/fixtures/prompt-arms/`.

## Run 1 — 2026-09-22T01:53:29Z

- Offline recall bench (`Tests/scripts/run-recall-bench.sh`), five frozen AMI
  **reference** transcripts, `claude-opus-5`, substring grounding.
- Scored by `score.py note`: an expected item survives on quote overlap or on
  item-text overlap at 0.55.

| arm | recall | action items | decisions | false keeps (act, dec) | cost |
|---|---:|---:|---:|---:|---:|
| `substring` (control) | 15/19 = 79% | 10/12 | 5/7 | 3 (1, 2) | $0.3838 |
| `sections-independent` | **16/19 = 84%** | 10/12 | 6/7 | 5 (0, 5) | $0.3748 |
| `action-coverage` | **16/19 = 84%** | 11/12 | 5/7 | 10 (4, 6) | $0.4181 |
| `both` | 15/19 = 79% | 9/12 | 6/7 | 8 (4, 4) | $0.4037 |

Ungrounded quotes were 0 on every arm and every meeting. Elapsed 110 s for all
four arms over all five transcripts.

### What each arm changes

- **`sections-independent`** adds a rule 6: build the two lists independently,
  and treat how much you found for one as saying nothing about the other.
- **`action-coverage`** rewrites rule 5 asymmetrically: cover every action item
  that clears rule 1, including one stated in passing or in a closing round,
  while keeping the precision bar for decisions. The asymmetry is deliberate —
  decisions already over-produce (9 kept against 7 expected in the Part B run),
  so a symmetric relaxation buys action items with decision noise.
- **`both`** is the two combined.

### Reading

`sections-independent` is the better of the two 84% arms. It gains its item in
decisions (6/7 against the control's 5/7), costs slightly less than the control,
and produces **zero** action-item false keeps. `action-coverage` reaches the
best action-item recall of any arm (11/12) but pays 10 false keeps for it
against the control's 3 — the trade that was predicted when precision was still
unmeasured, now priced.

`both` is worse than either half alone: 79%, and the only arm whose action-item
recall falls below the control's. Combining the two instructions appears to
weaken each.

ES2004a produced nothing at all under the control and under
`sections-independent`, and one item of three under `action-coverage`. It is the
only fixture no arm has moved meaningfully, and its three expected items sit
closest to rule 1 and rule 2's boundaries: a tentative offer, a group
instruction with no named owner, and a ruling read from a brief.

## The unresolved question

**The control scored 79% here against 57.9% in the Part B re-score, on the same
prompt, the same expected items and the same scorer.** The one deliberate
difference is the transcript: this bench feeds the committed reference
transcripts, and Part B fed WhisperKit output at word error rate 0.28 to 0.38.

If that gap is transcription, the constraint on Epic 4 is ASR quality rather
than the summarizer, and a prompt arm that reaches 84% here would still leave
Part B short of 80%. That is not established: a single run cannot separate a
transcription penalty from sampling variance, and the control moving 11 to 15
could be partly noise.

The check that settles it is one bench run over the WhisperKit transcripts the
2026-09-21 run left in the cache, holding the prompt, the expected items and the
scorer fixed so the transcript source is the only variable. It has not been run.

Until it has, no arm should be promoted to `Sources/Summarize/Prompts/summarize/`
and `min_item_recall` should not be raised: both would bank a bench number whose
relationship to the gate is unknown.
