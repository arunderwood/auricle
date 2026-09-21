# Sprint Change Proposal: Epic 4 Part B summarization recall

- **Date:** 2026-09-20
- **Trigger:** Story 4.10 Part B measured 42.1% item recall against an 80% floor.
- **Scope classification:** Moderate. Three new stories inside Epic 4, one scoring
  contract change, one maintainer decision gate. A fourth path (multi-pass
  extraction) is **out of scope** because it contradicts FR32; it is named here as
  the escalation route, not as work.
- **Status:** approved by the maintainer 2026-09-20. The planning-artifact edits in
  Section 4 have landed; the code stories go to the dev loop.
- **Corpus ruling (maintainer):** the AMI set is the Epic 4 gate, and a private
  corpus is not an option — the repository is public and recordings are never
  committed, so nothing built from them is reproducible. `Tests/regression/ami/README.md`
  said the opposite and has been reconciled (Section 4.5).

---

## Section 1: Issue summary

Story 4.10 Part B ran on 2026-09-21T00:52Z at revision `74a3d80`. It scored 26.3%
against an 80% floor and did not meet the criteria
(`Tests/fixtures/epic4-exit-results.md`). Replaying the same notes with corrected
match fragments raises the ceiling to 42.1%. The AMI regression suite reports
42.1% as well (`Tests/regression/ami/history.jsonl`). Cost was never the problem:
worst per-meeting $0.1019 against a $0.50 ceiling, total $0.3294 over five
fixtures.

Epic 4 is not accepted. The retrospective
(`_bmad-output/implementation-artifacts/epic-4-retro-2026-09-20.md`) leaves two
things open: a recorded Part B rerun, and a decision on the 42.1%-versus-80% gap.

### Evidence

Per meeting, from `Tests/regression/ami/history.jsonl`:

| meeting | audio | WER | kept | expected | recalled |
|---|---:|---:|---:|---:|---:|
| ES2002a | 21.2 min | 0.354 | 4 | 3 | 3 |
| ES2002b | 38.0 min | 0.339 | 4 | 8 | 2 |
| ES2003a | 19.0 min | 0.329 | 1 | 1 | 1 |
| ES2003b | 35.2 min | 0.283 | 5 | 4 | 1 |
| ES2004a | 17.5 min | 0.377 | 1 | 3 | 1 |
| **total** | | | **15** | **19** | **8 = 42.1%** |

`drop_count` is 0 and `ungrounded_quotes` is 0 on every meeting. Quote validation
is not discarding anything. The items never arrive.

---

## Section 2: Impact analysis

### F1. Under-production caps the score below the floor on its own

The summarizer kept 15 items against 19 expected. If every kept item matched an
expected one, the score would be 15/19 = **78.9%**, still under the floor. Better
alignment of the existing items cannot pass the gate. The summarizer has to emit
more items. Reaching 80% needs 16 of 19 recalled, against 8 today.

### F2. Output volume is flat and does not track meeting content

Kept counts are 4, 4, 1, 5, 1 against expected counts of 3, 8, 1, 4, 3. ES2002b
holds 8 expected items across 38 minutes and produced 4. ES2002a holds 3 across
21 minutes and produced 4. The summarizer returns roughly the same number of
items whatever the meeting contains.

ES2002a recalled 3/3 on three action items of the form "role X will work on Y
before the next meeting." ES2002b's first three expected action items have the
same shape and it recalled 2/8. The model can extract this pattern. It stops
early.

### F3. The prompt instructs the behaviour the gate penalises

`Sources/Summarize/Prompts/summarize/system.md` rule 5:

> Prefer precision over coverage. If you are unsure that something meets the
> definitions above, leave it out. A short list, or an empty array, is a correct
> answer.

Part B and `score.py` measure recall only. Neither counts a false keep. The prompt
optimises for a quantity no gate observes, against the one it does.

Rule 2 excludes "targets or requirements handed to the group from outside (a
company, a client, a brief)" and "ideas that are floated or debated." Three of
ES2002b's four expected decisions read as that class: target the 15-35 age
bracket, keep the function set basic, adopt the three-bucket categorisation as
the working frame. The prompt tells the model to drop what the fixture expects it
to keep. This is a contract mismatch between the prompt's definitions and the
curated labels, not only a model capability gap.

### F4. No experiment loop can measure a prompt change

Three harnesses exist. None fits.

| harness | transcripts | Claude call | recall score | blocker |
|---|---|---|---|---|
| `SummarizeEvalHarness` (`Tests/SummarizeTests/SummarizeEvalHarnessTests.swift`) | frozen | stubbed | automatic | its own doc comment: "It cannot measure prompt quality: the stubs never read the request, so a prompt change moves nothing here" |
| `StrategyComparisonRunner` (`Sources/Summarize/`) | supplied | real | **hand-scored** (`StrategyComparisonReportRenderer.swift:13`) | no automatic recall |
| `Tests/regression/ami/run.sh` | from audio | real | automatic (`score.py`) | runs WhisperKit; 40-160 s transcribe per meeting, needs cached audio and a scratch vault |

The loop the work needs — frozen reference transcript, real Claude call,
automatic recall score — does not exist. Every part does. Nothing joins them.
`StrategyComparisonArmSpec` already parses `substring:<absolute prompt dir>`, so
prompt-variant arms are supported today; only the scoring is missing.

### F5. The scorers disagree, and neither measures precision

Part B's script tests whether a short fragment from `exit-fragments.json` is a
substring of the note's block quote. `score.py` tests word overlap ≥ 0.5 against
the shorter of the two quotes. The same run scored 26.3% and 42.1%.

The retrospective calls these two independent measurements that agree. They are
not independent in the way that matters. **Both key on the reference quote and
neither compares item text.** A correct item quoted from a different passage
scores zero under both. Their agreement confirms the quote-overlap measurement,
not item recall. Seven of the 15 kept items matched no expected quote; whether
those are false keeps or right-item-wrong-quote is unknown and unmeasured.

Neither scorer counts false keeps, so any change that trades precision for recall
passes unobserved.

### F6. The 80% floor has no PRD backing

`grep '80%' prd.md` returns adoption and capture-rate targets only (`prd.md:85`,
`:420`, `:455`). The recall floor is declared in Story 4.10 (`epics.md:2263`) and
nowhere else. The PRD's stated resolution mechanism for summarization quality is a
benchmark, not a fixed number (`prd.md:330`, `:737`). Moving the floor is a
story-level edit. It needs no PRD amendment.

### F7. Multi-pass extraction is closed by FR32

`prd.md:515`, FR32 [MVP]: "auricle uses a single primary Claude call per meeting
(chain-of-summarize is explicitly deferred to v2+)."
`prd.md:599`, FR71 [v2+]: chain-of-summarize for transcripts ≥ 90 min.
`architecture.md:136` and Decision 5.6 (`architecture.md:1814`) both pin the MVP
default at one Opus call.

Map-reduce over transcript windows is the standard remedy for extraction recall on
long inputs, and the cost headroom exists (worst $0.1019 against $0.50, a 4.9x
margin). It is still out of scope here. Every AMI meeting is 17-38 min, so FR71's
own trigger does not apply either. Pulling multi-pass into MVP is a PRD and
architecture amendment, and belongs to a PM/Architect escalation, not to this
proposal.

### Artifact impact

| artifact | impact |
|---|---|
| PRD | **none.** The floor is not in the PRD (F6). FR32 constrains the solution space (F7). |
| Architecture | **none** for the proposed scope. A multi-pass escalation would amend `architecture.md:136` and Decision 5.6. |
| UX design | **none.** No user-facing surface changes. |
| `epics.md` | Three stories added to Epic 4; the Story 4.10 sequencing line extended. The 80% number is unchanged by this proposal. |
| `spec-4-10-*.md` | `status_detail` updated to name the recall gap as the blocker, not the maintainer's availability. |
| `Tests/regression/ami/README.md` | Contradicts the corpus ruling; must be reconciled. |
| `Tests/regression/ami/thresholds.json` | `min_item_recall: 0.35` is a tripwire below the baseline, not a target. Raise it as recall rises. |
| `sprint-status.yaml` | Three new story keys. Retro action item 6 (repair the stale Epic 4 keys) is already done: `epic-4` reads `in-progress`, 4.1-4.9 `done`, 4.10 `in-progress`. |
| `Sources/Summarize/Prompts/summarize/system.md` | Rules 2 and 5 rewritten under Story 4.13. |
| `Tests/regression/ami/score.py` | Item-text matching and a false-keep count added under Story 4.12. |

---

## Section 3: Recommended approach

**Direct Adjustment (Option 1), with a pre-committed decision gate.**

Rollback (Option 2) was not viable: nothing in stories 4.1-4.9 caused the gap, and
reverting them removes the pipeline that measures it. An MVP scope review (Option
3) is premature: the gap has not yet been attacked with the cheapest available
lever, and the floor it misses is a story-level number with no PRD backing.

The sequence attacks measurement before quality, because three of the six findings
are measurement defects and one of them (F5) may be inflating the size of the gap.

### Story 4.11 — Offline recall bench

Join the three existing pieces. Feed the frozen reference transcripts under
`Tests/SummarizeTests/Fixtures/eval/` and `Tests/regression/ami/reference/` to
`StrategyComparisonRunner`, make a real Claude call per arm, score the rendered
note with `score.py`'s scorer, and print recall per arm per meeting. No WhisperKit,
no audio, no vault, no state database.

Lands in `Sources/Summarize/` behind a CLI verb, per the AGENTS.md pitfall that
`App/`-only logic has no test coverage. The rig's prompt-directory grammar already
exists; this story adds scoring and a fixture loader.

**Effort:** 4 h. **Cost:** ~$0.25 per full-set arm. **Risk:** low.

### Story 4.12 — Score the item, count the false keeps

Two changes to the recall contract, in `score.py` and in the bench:

1. An expected item counts as recalled if **either** the quote overlaps ≥ 0.5
   **or** the item text matches the expected text above a stated threshold. The
   exit criterion in `epics.md:2263` says expected items must "survive grounding" —
   it is about the item, not about which sentence the model chose to quote.
2. Report `false_keeps`: kept items matching no expected item. Recall alone cannot
   catch a prompt change that buys coverage with noise.

Then re-score the 2026-09-21 notes. This answers the open question from F5: of the
seven unmatched kept items, how many are the right item quoted from the wrong
passage. The notes are in the scratch vault; if they were not kept, one bench run
regenerates them for ~$0.25.

**This may move the measured number without changing the pipeline.** That is a
legitimate correction to a scorer that never compared items, not a threshold
dodge — and F1 says it cannot be enough on its own, because 15/19 = 78.9% is the
hard ceiling until the summarizer emits more.

**Effort:** 4 h. **Cost:** ≤ $0.25. **Risk:** low.

### Story 4.13 — Prompt recall pass

Iterate prompt arms on the bench. Named starting points, each traceable to a
finding:

- Reverse rule 5's precision bias, now that 4.12 measures the precision cost (F3).
- Resolve rule 2's exclusion of "targets handed to the group from outside" against
  the labels it currently contradicts (F3). Either the rule narrows or the three
  ES2002b decisions come out of the fixture with a recorded rationale.
- Require the quote to carry the decisive line rather than the opening of the
  passage (F5).
- State an expected item count proportional to transcript length, against the flat
  4-5 the model returns today (F2).

Stop when the bench reads ≥ 80% recall with false keeps no worse than the
baseline 4.12 records, or when arms stop improving.

**Effort:** 1 day. **Cost:** ~$3 (≈10 arms × 5 meetings × $0.05). **Risk:** medium.
Single-call prompt work may not reach 80% on AMI.

### Decision gate — maintainer, after 4.13

Pre-committed now so it is not relitigated under a result:

| bench recall after 4.13 | action |
|---|---|
| ≥ 80% | Rerun Part B on the full pipeline. Record it. Epic 4 exits. |
| 65-79% | Maintainer chooses: escalate to a multi-pass amendment (PM/Architect, FR32 and FR71 reopened), or move Story 4.10's floor to the achieved number with the rationale recorded in `epics.md`. |
| < 65% | Escalate. A prompt is not the lever, and moving the floor that far would not be honest about the product. |

### Part B rerun

Retro action item 3, already `in-progress`. Runs after the gate clears. Records to
`Tests/fixtures/epic4-exit-results.md`.

**Effort:** 1 h maintainer. **Cost:** ~$0.35.

### Totals before any fork

~2.5 days of dev-agent work, ~1.5 h maintainer, under $5 of API credit.

### Risks

- **AMI may be the wrong difficulty.** Far-field four-speaker scenario meetings at
  28-38% WER are harder than a laptop call on a headset. The maintainer ruled that
  AMI stays the gate, so 80% on AMI is a conservative floor. If 4.13 stalls, that
  conservatism is the first thing to re-examine, and the README reconciliation
  below is where the ruling gets written down.
- **Recall and precision trade.** A false action item costs a user more than a
  missed one. 4.12 exists so the trade is visible before it is made.
- **4.12 could be read as moving the goalposts.** Mitigated by landing it before
  any prompt change, by reporting the old and new numbers side by side, and by F1:
  the item-text change cannot lift the ceiling past 78.9% by itself.

---

## Section 4: Detailed change proposals

### 4.1 `epics.md` — Epic 4 story list

**OLD** (`epics.md:2323`, Epic 4 summary):

```
- **Story sequencing matters:** 4.1 → 4.2 → 4.3 → 4.4 → 4.5 → 4.6 → 4.7 → 4.8 → 4.9 → 4.10 (4.9 cannot land before 4.1–4.8; 4.10 is the explicit gate)
```

**NEW:**

```
- **Story sequencing matters:** 4.1 → 4.2 → 4.3 → 4.4 → 4.5 → 4.6 → 4.7 → 4.8 → 4.9 → 4.10 (4.9 cannot land before 4.1–4.8; 4.10 is the explicit gate)
- **Recall remediation (added 2026-09-20, sprint change proposal):** 4.11 → 4.12 → 4.13 land after 4.10's first Part B run and before its rerun. They exist because Part B measured 42.1% item recall against 4.10's 80% floor. 4.13 ends at a maintainer decision gate; multi-pass extraction is not among its options while FR32 stands.
```

**Rationale:** the three stories are remediation for a measured gate failure, not
new product scope. The sequencing note records why they sit after 4.10.

Three new story sections are added after Story 4.10 with the acceptance criteria
summarised in Section 3. They are written in full when this proposal is approved.

### 4.2 `epics.md` — Story 4.10 exit criteria

**No change to the 80% number in this proposal.** The gate's floor moves only
through the decision gate, and only with a rationale recorded in place.

One clarifying edit, so that Story 4.12's scoring change does not read as a
contradiction of the epic:

**OLD** (`epics.md:2263`, Part B):

```
**And** across the set at least 80% of expected action items and decisions survive grounding, or the script fails with "Epic 4 exit criteria not met: <metric> = <value>"
```

**NEW:**

```
**And** across the set at least 80% of expected action items and decisions survive grounding, or the script fails with "Epic 4 exit criteria not met: <metric> = <value>"
**And** an expected item counts as surviving when the note carries that item, whether matched by quote overlap or by item text; the scorer also reports false keeps, so a recall gain bought with noise is visible in the same output
```

**Rationale:** the criterion has always been about the item surviving. The original
wording did not say how a match is decided, and the first implementation chose
quote overlap alone. F5 shows that choice silently fails a correct item quoted
from a different sentence.

### 4.3 `Sources/Summarize/Prompts/summarize/system.md` — rule 5

**OLD:**

```
5. Prefer precision over coverage. If you are unsure that something meets the definitions above, leave it out. A short list, or an empty array, is a correct answer. Report each task or decision once.
```

**NEW** (starting point for Story 4.13; the bench picks the final wording):

```
5. Cover the meeting. Report every task and every decision that meets the definitions above, once each. An empty array is correct only when the meeting settled nothing and no one took anything on. Do not pad the list with items that fail the definitions.
```

**Rationale:** the gate measures recall and nothing measures precision, so the
current rule optimises against the only observed metric. The replacement keeps the
definitional bar in rules 1 and 2 and drops the bias toward brevity. Story 4.12
lands first so the precision cost is measured, not assumed.

### 4.4 `Tests/regression/ami/score.py` — recall and precision

**OLD** (`score.py`, `meeting`):

```python
wanted = [("Action Items", i["quote"]) for i in expected["action_items"]] + [("Decisions", i["quote"]) for i in expected["decisions"]]
survived = sum(1 for heading, quote in wanted if any(overlap(quote, k) >= RECALL_OVERLAP for k in quotes[heading]))
result["expected_items"] = len(wanted)
result["recalled_items"] = survived
```

**NEW** (shape, not final code): `wanted` carries each expected item's `text`
alongside its `quote`; `note_quotes` returns each bullet's item text as well as its
block quote; an item survives on quote overlap **or** item-text overlap; and
`result["false_keeps"]` counts kept items matching no expected item.

**Rationale:** F5. The scorer compares only quotes today, so a correct item quoted
from a different passage scores zero, and a fabricated item costs nothing.

### 4.5 `Tests/regression/ami/README.md` — corpus ruling

**OLD:**

```
The tradeoff is precision: a short fragment can match a block quote about something else, which counts an item as surviving when it did not. That inflates the pass rate rather than deflating it, so treat a passing AMI run as evidence the harness works end to end, not as the Epic 4 acceptance result. Acceptance needs recordings whose expected quotes were written from the transcription the pipeline actually produced.
```

**NEW:**

```
The tradeoff is precision: a short fragment can match a block quote about something else, which counts an item as surviving when it did not. Read a passing fragment score as an upper bound, and read `score.py`'s item recall as the acceptance number.

AMI is the Epic 4 acceptance corpus. It is harder than the target workload — far-field four-speaker scenario meetings, word error rate 0.28 to 0.38, against a laptop call on a headset — so 80% here is a conservative floor, not an equivalent one. A private corpus whose expected quotes come from the pipeline's own transcription would measure the real workload more directly; it is not what Epic 4 exits against.
```

**Rationale:** the file currently rules out the use the maintainer has chosen for
it. Left as is, the next reader finds the acceptance result contradicted by the
corpus's own documentation. The replacement keeps the caveat that produced the
original sentence and states where the ruling landed.

### 4.6 `spec-4-10-*.md` — frontmatter

**OLD:**

```
status_detail: 'Part A (CI pipeline test) is done. Part B (live run) awaits the maintainer: it needs private recordings, real WhisperKit and live Anthropic calls, and has not been run.'
```

**NEW:**

```
status_detail: 'Part A (CI pipeline test) is done. Part B ran on 2026-09-21 against the AMI set and did not meet the criteria: 26.3% by the fragment scorer, 42.1% item recall. The blocker is summarizer recall, not maintainer availability. Stories 4.11 to 4.13 remediate it; the rerun follows their decision gate.'
```

**Rationale:** the current text says the story waits on the maintainer. It ran.

### 4.7 `sprint-status.yaml`

Add after `4-10-exit-criteria-gate-ci-pipeline-test-live-run: in-progress`:

```yaml
  4-11-offline-recall-bench: backlog
  4-12-item-text-recall-and-false-keep-scoring: backlog
  4-13-prompt-recall-pass: backlog
```

`epic-4-retrospective: done` stays where it is; the retrospective is complete and
these stories come from it.

---

## Section 5: Implementation handoff

**Scope: Moderate.** Backlog reorganisation inside one epic, no PRD or
architecture change, one pre-committed decision gate.

| recipient | responsibility |
|---|---|
| Developer agent | Stories 4.11, 4.12, 4.13. Writes the three story sections into `epics.md` first, then implements in order. |
| Maintainer | The decision gate after 4.13. The Part B rerun. |
| PM / Architect | Only on escalation: bench recall below 65%, or the maintainer choosing multi-pass at 65-79%. That reopens FR32, FR71 and Decision 5.6. |

### Success criteria

1. The bench reports recall and false keeps per arm per meeting, from frozen
   transcripts, with no WhisperKit and no vault, in under two minutes and under
   $0.30 per arm.
2. The seven unmatched kept items from the 2026-09-21 run are classified: false
   keep, or right item quoted from the wrong passage.
3. Bench recall reaches ≥ 80% with false keeps no worse than the 4.12 baseline —
   or the decision gate is exercised on the record.
4. `Tests/fixtures/epic4-exit-results.md` holds a Part B result recorded against
   whatever floor Story 4.10 states at that time.

### What this proposal does not do

- It does not move the 80% floor. That is the decision gate's to make, with a
  rationale written into `epics.md` where the number lives.
- It does not add multi-pass extraction. FR32 forbids it at MVP and F7 explains
  why that stands until a PM/Architect amendment says otherwise.
- It does not change the corpus. AMI is the gate, and a corpus that cannot be
  checked into a public repository cannot gate a build.
