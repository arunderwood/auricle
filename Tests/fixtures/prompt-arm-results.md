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
only fixture no arm moved meaningfully. Its three expected items do sit close to
rule 1 and rule 2's boundaries — a tentative offer, a group instruction with no
named owner, and a ruling read from a brief — but run 2 below gives a simpler
reason to prefer: its WhisperKit transcript is 34% shorter than the reference,
the largest loss in the set.

## Run 2 — transcript source held as the only variable

The control scored 79% on run 1 against 57.9% in the Part B re-score, on the
same prompt, the same expected items and the same scorer. Run 2 settles which
part of that is the transcript by scoring the same two arms over the WhisperKit
transcripts the 2026-09-21 run left in the cache. Everything else is identical.

| arm | reference transcripts | WhisperKit transcripts | difference |
|---|---:|---:|---:|
| `substring` (control) | 15/19 = 79% | 12/19 = 63% | **-3 items** |
| `sections-independent` | 16/19 = 84% | 14/19 = 74% | **-2 items** |

The independent Part B re-score put the control on WhisperKit output at 11/19.
Run 2 puts it at 12/19. One item apart, which bounds run-to-run sampling
variance at roughly one item and leaves the rest attributable to the transcript.

WhisperKit output is 14% to 34% shorter than the reference for the same audio:

| meeting | reference | WhisperKit | lost |
|---|---:|---:|---:|
| ES2002a | 16,486 | 13,690 | 17% |
| ES2002b | 42,870 | 32,098 | 25% |
| ES2003a | 11,911 | 9,597 | 19% |
| ES2003b | 33,124 | 28,401 | 14% |
| ES2004a | 16,980 | 11,269 | 34% |

That is missing text, not substitution noise. An item whose only statement in
the meeting was not transcribed cannot be extracted by any prompt.

## Conclusion

**The summarizer is not the constraint. Transcription is.**

Given a clean transcript of the same audio, the shipped prompt already recalls
79% and the promoted arm 84%, both at or above Story 4.10's floor. On the
pipeline's own WhisperKit output the same prompts reach 63% and 74%. The
decomposition, in items out of 19:

- Transcription costs 2 to 3 items.
- The prompt arm recovers 2 items on WhisperKit output, 1 on clean.
- Sampling variance is about 1 item.

`sections-independent` is promoted to `Sources/Summarize/Prompts/summarize/`.
It wins on both transcript sources, adds no cost, and does not trade precision
for recall — action-item false keeps stay at the control's level. It is the
right change regardless of how the gate is resolved.

It does not clear the gate. 80% of 19 is 16 items; the promoted arm reaches 14
on WhisperKit output. The remaining two items are behind transcription, so
Story 4.13's own stopping condition cannot be met by a prompt.

**Multi-pass summarization is the wrong lever and should not be the
escalation.** Story 4.13's decision gate offered it for the 65-79% band, but
that gate was written while the gap was believed to be summarizer recall. A
second summarization pass cannot recover text that is not in the transcript.
The PRD already names the right response: "If WhisperKit transcription is
inadequate, the Parakeet-TDT alternate ASR path is the next step"
(`prd.md:426`).

`min_item_recall` is left at 0.35. Raising it needs a recorded full-pipeline
regression run under the promoted prompt, and `history.jsonl` has none yet.
