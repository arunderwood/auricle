# Sprint Change Proposal: Epic 4 exit lever — the transcript was never complete

- **Date:** 2026-09-21
- **Trigger:** the two open decisions Story 4.13 left in `sprint-status.yaml`: which
  lever Epic 4 exits on, and whether Story 4.10's 80% floor stands.
- **Scope classification:** Moderate. One new story inside Epic 4, one regression
  metric, one recorded rerun, and planning-artifact edits that retire the
  Parakeet-TDT line as "the designed response". No epic is added or removed.
- **Status:** approved by the maintainer 2026-09-21, on the recommended path:
  the 80% floor stands. The planning-artifact edits in Section 4 have landed
  (4.1 to 4.5 and 4.7; 4.6 is Story 4.14's work). The code change that Section 3
  describes exists in the worktree `bmad-build-autocomplete-stories-6c0c4d` as
  an uncommitted diff of two files with its unit tests passing; Story 4.14 lands
  it.
- **Research:** `research/technical-on-device-macos-asr-for-long-far-field-m-2026-09-21/research.md`
  holds the ASR landscape, the sources, and every measurement quoted here
  (Appendix A there).

---

## Section 1: Issue summary

Story 4.13 established that the summarizer clears 80% item recall on reference
transcripts and misses it on the pipeline's own WhisperKit output, which is 14%
to 34% shorter than the reference for the same audio. It framed the remaining
choice as Parakeet-TDT versus a lower floor.

The shortfall is neither model accuracy nor a chunking problem. It is one
WhisperKit decoding option interacting with one the app sets on purpose.
WhisperKit ends a 30 second window with no text when the first sampled token's
log-probability falls under -1.5, and relies on a temperature fallback to decode
that window again. The app disables the fallback so that a re-run produces the
same words (Story 4.1, spec line 79). With no fallback the empty window is seeked
past, and its speech leaves the transcript without an error.

### Evidence

Every number below names its transcript source. The same prompt differs by 16
points between reference and pipeline text, so a recall figure without a source
is not a figure.

**Where the text goes.** Reference content words aligned against the app's cached
WhisperKit transcripts, fillers and stutters removed from both sides:

| meeting | reference words | app transcript | words in dropped blocks of 25+ with no output |
|---|---:|---:|---:|
| ES2002a | 2,286 | 82% | 322 (14%) |
| ES2002b | 6,203 | 77% | 850 (14%) |
| ES2003a | 1,869 | 76% | 327 (18%) |
| ES2003b | 5,222 | 81% | 588 (11%) |
| ES2004a | 2,327 | 71% | 440 (19%) |
| **total** | **17,907** | **78%** | **2,527 (14%)** |

Every block of 25 words or more is a true drop with zero hypothesis text. None is
garbled. The remaining loss is scattered short substitutions, the ordinary
far-field word error.

**The reproduction.** WhisperKit's own CLI, built from the pinned 1.1.0 checkout,
with the app's flags plus the first-token threshold at its library default of
-1.5, produces the app's cached ES2004a transcript to the word: 1,662 content
words, 440 dropped, the same three quote scores. With the threshold unset and
nothing else changed, the same model keeps 2,044 words and drops none.

**The fix, over all five meetings, WhisperKit CLI:**

| configuration | reference content kept | dropped blocks | expected-item quotes present | deterministic |
|---|---:|---:|---:|---|
| app today: gate on, fallback off | 78% | 14.1% | 16 / 19 | yes |
| gate off, fallback off | **90%** | **0.0%** | **18 / 19** | yes |
| gate on, fallback 5 (WhisperKit default) | 85% | 5.8% | 18 / 19 | no |
| gate on, fallback 5, VAD chunking, ES2004a only | 78% | 12.7% | 1 / 3 | no |

**The fix, in the app, full pipeline** (transcribe, diarize, summarize, promoted
prompt, `Tests/regression/ami/run.sh`, not recorded to `history.jsonl`):

| meeting | WER | speakers | kept | recall | false keeps | cost |
|---|---:|---|---:|---:|---:|---:|
| ES2002a | 0.249 | 4 of 4 | 3 | 3 / 3 | 0 | $0.058 |
| ES2002b | 0.224 | 4 of 4 | 7 | 6 / 8 | 1 | $0.126 |
| ES2003a | 0.211 | 4 of 4 | 1 | 1 / 1 | 0 | $0.039 |
| ES2003b | 0.197 | 4 of 4 | 6 | 4 / 4 | 2 | $0.117 |
| ES2004a | 0.229 | 5 of 4 | 0 | 0 / 3 | 0 | $0.043 |
| **total** | **0.20 to 0.25** | | **17** | **14 / 19 = 74%** | **3** | **$0.38** |

The stage recorded the same transcript byte counts as the CLI measurement on
every meeting, so the two tables describe the same transcripts. WER against the
verbatim reference fell from 0.28 to 0.38 in `history.jsonl` to 0.20 to 0.25.
Item recall is 74%, the same figure Story 4.13 measured on the unfixed
transcripts.

---

## Section 2: Impact analysis

### F1. The lost text is a decoding gate, and the fix is one option

`WhisperKitTranscriber.decodeOptions` inherits `firstTokenLogProbThreshold: -1.5`
from WhisperKit. `TextDecoder.decodeText` ends the window on that condition
before any content token is sampled; `DecodingFallback` then asks for a
temperature fallback; `temperatureFallbackCount: 0` refuses it; `SegmentSeeker`
gets an empty result and advances a full window. Setting the threshold to `nil`
removes the gate. Silence is still detected by `noSpeechThreshold`, which needs
both a high no-speech probability and a low mean log-probability, and which did
not fire on any of the five meetings.

The determinism rationale in Story 4.1 stands. The fix keeps the fallback off.
Re-enabling the fallback instead recovers less, is non-deterministic, and costs
25% more transcription time.

### F2. The fix does not move the item gate

Full pipeline, promoted prompt: 74% before the fix (Story 4.13's expectation for
the rerun) and 74% after it. The two items still missing sit in
ES2002b (6 of 8) and ES2004a (0 of 3). ES2004a's three expected-item quotes are
present in the fixed transcript at overlaps of 0.50, 0.95 and 1.00, and the
summarizer emits zero items for that meeting on every transcript source Story
4.13 tried, the human reference included. That is a summarizer behaviour, not a
transcription one.

### F3. On the bench, more transcript meant fewer items

Same day, same prompt, offline bench, all utterances labelled `Speaker_1`:

| transcript set | item recall | false keeps |
|---|---:|---:|
| app cached transcripts | 13 / 19 = 68% | 7 |
| fixed transcripts, run 1 | 10 / 19 = 53% | 5 |
| fixed transcripts, run 2 | 10 / 19 = 53% | 5 |

Run-to-run variance on one set is about one item; this gap is three items on two
runs. Story 4.13 inferred a two to three item transcription cost by comparing
reference against WhisperKit text, but the reference also carries four real
speaker labels and verbatim disfluencies, so that comparison changed three
variables. The single-variable comparison says completeness alone does not move
the item count, and on the bench it moves it the wrong way. The pipeline scored
14 of 19 on the same transcripts byte for byte, and the summarize stage hands
the summarizer the raw `transcript.json` with every utterance labelled
`Speaker_1`, so speaker labels are not the difference. Some other summarizer
input differs between the two call sites, and until it is named the bench is
not a proxy for the pipeline on transcription changes.

### F4. Word error rate hid the drop

`history.jsonl` records WER 0.28 to 0.38 against a verbatim reference. That
number mixes stripped fillers, substitutions and vanished windows. Nothing in the
suite reports how many reference words fall in a stretch with no hypothesis text
at all, which is the only metric that would have caught this at Story 4.1.

### F5. The Parakeet line is stale, and no candidate has evidence on this workload

From the research report: Argmax renamed WhisperKit to argmax-oss-swift in May
2026 and ships Parakeet only inside its paid Pro SDK. The open Swift route,
FluidAudio, is 0.x with breaking renames, documents no timestamps on its ASR
result, and fixed a whole-window blank bug on 2026-09-11. Apple positions
SpeechAnalyzer for "long-form and distant audio" and no independent English
meeting measurement exists. The Open ASR Leaderboard's AMI column is headset
audio cut under 30 seconds; its long-form track has no AMI. Parakeet-TDT does
lead Whisper large-v3 on headset AMI under one normalizer, 11.39 against 15.95,
and that gap is real. It is measured on close-talk short segments, and nothing
published measures retention on a 40 minute room recording for any model. Only
this project can.

### F6. The floor question is now a summarizer question

The 80% floor is reachable on clean text: 84% with the promoted prompt on
reference transcripts. On the pipeline's own text, with the transcription defect
removed, it is 74%. The ceiling exists. Whatever closes the gap now is work on
the summarizer or on the fixtures, and the decision gate in Story 4.13 was
written for neither.

### Artifact impact

| artifact | impact |
|---|---|
| `epics.md` Story 4.13 decision gate (lines 2402 to 2406) | names Parakeet as the alternative; superseded |
| `epics.md` Epic 4 story list and summary | add Story 4.14 |
| `prd.md:336`, `prd.md:426`, `prd.md:718`, `prd.md:720` | Parakeet-TDT as "the designed response" and "spike before the transcription stage locks"; stale |
| `architecture.md:81` | "locked default" stands; add the decoding constraint |
| `spec-4-1-whisperkit-transcribe-stage.md` line 271 | "Story 4.9's evidence decides whether to revisit" the fallback; the revisit happened, the fallback stays off, the gate goes |
| `Tests/regression/ami/score.py`, `thresholds.json`, `README.md` | retention metric and limit |
| `Tests/WhisperKitTranscriberTests/WhisperKitSegmentMappingTests.swift` | pin the option |
| `sprint-status.yaml` | close the lever decision, keep the rerun, add 4.14 and 4.15 |
| UX specification | no impact |

---

## Section 3: Recommended approach

**Direct adjustment, with the lever decision closed and the floor decision made
explicit rather than moved.**

### Decision 1: the lever

The ASR lever is closed by a decoding option, not by a model swap. Story 4.14
lands the option, pins it, adds the retention metric that would have caught it,
and records the Part B rerun. No Parakeet work starts. The Parakeet spike becomes
conditional: it runs only if a recorded full-pipeline run under the fix shows
expected-item quotes absent from the transcript, rather than present and
unextracted. That condition is measurable with the tools that exist, in a day
and under a dollar, because the recall bench accepts any directory of
transcripts.

Rollback was considered and rejected: no completed story is wrong. An MVP review
was considered and rejected: the MVP scope is intact and the PRD's transcription
requirement, FR17, is met better after the fix than before.

### Decision 2: the floor

**Recommended: the 80% floor stands, and Epic 4 does not exit on this run.** The
plain statement the maintainer asked for: moving the floor to 74% would foreclose
recovering two items that the summarizer extracts from clean text and does not
extract from the pipeline's text of the same meetings, and one meeting on which
the summarizer produces nothing at all from any text. Those are defects with
reproductions, not noise. (Approved 2026-09-21.)

What the floor now waits on is Story 4.15, a bounded summarizer story with a
different shape from Story 4.13. Story 4.13 varied the prompt over the whole set.
Story 4.15 starts from two reproductions: ES2004a produces zero items from every
source, and a fuller un-diarized transcript lowers the count. Its stop condition
is 16 of 19 on a recorded full-pipeline run under the fix, or a written ruling
that ES2004a's three items leave the fixture with the rationale in that fixture's
`expected.json` notes, per the 2026-09-20 proposal's rule that fixture changes
are explicit.

The alternative, for the maintainer to choose instead: move the floor to 74%, the
measured full-pipeline figure under the fix, and exit Epic 4 on
the recorded rerun. If chosen, `epics.md` records that 84% on reference
transcripts is the known ceiling and that the residual is summarizer
under-production on ES2002b and ES2004a, so nobody later reads 74% as the model's
limit.

### Story 4.14 — Retention: unset the first-token gate, measure dropped text

- `WhisperKitTranscriber.decodeOptions` sets `firstTokenLogProbThreshold: nil`,
  with the constraint documented beside the fallback rationale.
- `decodeOptionsForceEnglishAndDisableEveryNonDeterministicPath` pins it.
- `score.py meeting` reports `dropped_reference_words` and
  `dropped_reference_fraction`: reference content words that fall in a run of 25
  or more with at most a quarter as many hypothesis words against it, fillers
  and immediate repeats removed from both sides. `report` prints it per meeting.
  `thresholds.json` gains `max_dropped_reference_fraction`, calibrated from the
  recorded rerun with the same one-item slack the other limits carry.
- `Tests/regression/ami/README.md` documents the metric and why WER cannot stand
  in for it.
- Story 4.10 Part B is rerun under the fix and the promoted prompt and recorded
  with `AURICLE_AMI_RECORD=1` three times. `report` gates on the median of the
  newest three complete runs, and `min_item_recall` rises from that median.
  Decided 2026-09-21 after Story 4.15 showed the summarizer samples at the API
  default temperature, which `claude-opus-5` does not let a request change, and
  three runs of byte-identical input scored 10, 10 and 14 of 19. The bar stays
  16 of 19; the median keeps one draw from deciding it.

Effort: three hours of work plus a 20 minute run at about $1. Risk: low. The
change is one option with a byte-for-byte reproduction on both sides.

### Story 4.15 — Summarizer under-production on ES2002b and ES2004a

- Diff the kept items between the cached-transcript and fixed-transcript bench
  runs of 2026-09-21, meeting by meeting, and name what the summarizer stops
  emitting when the input grows.
- Reproduce ES2004a's zero output on the reference transcript and characterise
  it: which rule the three expected items fall under, and whether the model
  reasons them out or never proposes them.
- One arm per finding, single-variable, through the recall bench. A diarized
  WhisperKit-transcript arm, read through `attribution.json`, tests whether
  per-speaker labels are a recall lever; today's summarize stage does not pass
  them, so that arm measures a possible pipeline change, not the pipeline as
  shipped. The first single-variable check is the pipeline-versus-bench gap on
  identical text (F3).
- Stop condition as stated under Decision 2, with recall read as the median of
  three recorded runs; a claimed arm improvement likewise rests on the median
  of three bench runs.

Effort: one to two days, about $3 in bench runs. Risk: medium. The first two
bullets may end in a fixture ruling rather than a prompt change, and that is an
acceptable end.

### Part B rerun

Folded into Story 4.14 so that the recorded number is the fixed pipeline, not the
defective one. The `story-4-13-rerun-part-b-under-the-promoted-prompt` action
item stays open until that row exists.

### Totals

Two stories, one recorded run, about four days of maintainer-adjacent work, under
$5 in API credit. Epic 4 remains `in-progress` until Story 4.15 stops.

### Risks

- **The second early-stop path.** WhisperKit issue #525 documents windows that
  end on an end-of-transcript prediction at the forced timestamp position, which
  the option does not cover. It did not fire on these five meetings. The
  retention metric is the guard; if it rises on a later run, the fix is a source
  patch or a version bump, not a model swap.
- **Determinism claim.** The regression suite asserts nothing about byte-identical
  re-runs today. The fixed transcripts were identical between the CLI and the
  app on all five meetings, which is the same evidence Story 4.1 relied on.
- **The bench diverges from the pipeline on transcription changes.** F3 shows it,
  on identical text. Story 4.15's first task is to find the summarizer input
  that differs between the two call sites, and until then a bench number about
  a transcript change is not a pipeline number.

---

## Section 4: Detailed change proposals

### 4.1 `epics.md` — Story 4.13 decision gate, lines 2402 to 2406

OLD:

> **Given** the story ran and disproved the premise its decision gate was written on (`spec-4-13-prompt-recall-pass.md`, 2026-09-21)
> **When** the gate above is exercised
> **Then** the multi-pass option is struck: the same prompt scores 84% on reference transcripts and 74% on the pipeline's own WhisperKit output of the same audio, which is 14% to 34% shorter, so the binding constraint is transcription and a second summarization pass cannot recover text that was never transcribed
> **And** the choice is between the Parakeet-TDT alternate ASR path that `prd.md:426` already names as the designed response to inadequate transcription, and moving Story 4.10's floor to what the pipeline achieves
> **And** the 80% floor is reachable on clean text, so moving the floor forecloses a ceiling that exists

NEW:

> **Given** the story ran and disproved the premise its decision gate was written on (`spec-4-13-prompt-recall-pass.md`, 2026-09-21)
> **When** the gate above is exercised
> **Then** the multi-pass option is struck: the same prompt scores 84% on reference transcripts and 74% on the pipeline's own WhisperKit output of the same audio, so a second summarization pass cannot recover text that was never transcribed
> **And** the transcription shortfall is resolved by Story 4.14, not by an ASR swap: the missing text was whole 30-second windows that WhisperKit's first-token log-probability gate ended empty while the app's disabled temperature fallback refused to retry them (`sprint-change-proposal-2026-09-21.md`); unsetting the gate restores 12 points of reference content and drops no window, and the full pipeline under the fix scores 74% on diarized text with WER 0.20 to 0.25
> **And** the 80% floor stands: it is reachable on clean text, the residual after the fix is summarizer under-production on ES2002b and ES2004a, and Story 4.15 owns it with a stop condition of 16 of 19 on a recorded full-pipeline run or an explicit fixture ruling
> **And** the Parakeet-TDT path is conditional, not designed: it starts only if a recorded full-pipeline run under Story 4.14 shows expected-item quotes absent from the transcript rather than present and unextracted

Rationale: the gate's two options were written before the mechanism was known.
Both are now wrong, and the epic needs to say what replaced them.

### 4.2 `epics.md` — Epic 4 story list: add Stories 4.14 and 4.15

Insert after Story 4.13, in the same format as Stories 4.11 to 4.13:

> ### Story 4.14: Retention — Unset the First-Token Gate, Measure Dropped Text
>
> As the maintainer, I want the transcribe stage to keep every window WhisperKit can decode and the regression suite to report how much reference text has no transcript at all, so that a decoding gate cannot remove a fifth of a meeting without a number changing.
>
> **Given** `WhisperKitTranscriber.decodeOptions`
> **When** the transcribe stage runs
> **Then** `firstTokenLogProbThreshold` is `nil` and `temperatureFallbackCount` stays 0, and the decoding-options test pins both
>
> **Given** `score.py meeting` over a scored meeting
> **When** it reports
> **Then** it adds the reference content words that fall in a run of 25 or more with no hypothesis text, as a count and a fraction, and `report` prints the fraction per meeting and enforces `max_dropped_reference_fraction` from `thresholds.json`
>
> **Given** the fix and the promoted prompt
> **When** Story 4.10 Part B is rerun with `AURICLE_AMI_RECORD=1`
> **Then** `history.jsonl` carries the first full-pipeline row for the promoted prompt and `min_item_recall` is raised to guard it
>
> ### Story 4.15: Summarizer Under-Production on ES2002b and ES2004a
>
> As the maintainer, I want to know why the summarizer emits nothing for ES2004a from any transcript and fewer items from a fuller un-diarized transcript, so that the next prompt change targets a reproduced defect rather than the whole set.
>
> **Given** the 2026-09-21 bench runs over the cached and the fixed transcripts
> **When** their kept items are diffed per meeting
> **Then** the story records what the summarizer stops emitting when the input grows
>
> **Given** ES2004a's reference transcript
> **When** it is summarized with the promoted prompt
> **Then** the story records which rule each of the three expected items falls under and whether the model proposes and discards them or never proposes them
>
> **Given** the bench's fixture loader
> **When** a WhisperKit-transcript arm is added
> **Then** the arm can carry the diarized speaker labels from `attribution.json`, so the bench can test whether per-speaker labels are a recall lever; the summarize stage as shipped passes the `Speaker_1`-only `transcript.json`, so this arm measures a possible pipeline change, not the pipeline as shipped
>
> **Given** arms run one finding at a time
> **When** a recorded full-pipeline run reaches 16 of 19, or the maintainer rules that ES2004a's items leave the fixture with the rationale in its `expected.json` notes
> **Then** the story stops and Epic 4 exits through Story 4.10

And in the Epic 4 summary, extend the recall-remediation line:

OLD:

> 4.13 ends at a maintainer decision gate; multi-pass extraction is not among its options while FR32 stands.

NEW:

> 4.13 ended at a maintainer decision gate that `sprint-change-proposal-2026-09-21.md` resolved: 4.14 removes the WhisperKit decoding gate that was dropping whole windows and adds a retention metric; 4.15 owns the summarizer residual. Multi-pass extraction is not among the options while FR32 stands.

Rationale: two bounded stories with stop conditions, in the place the epic
already keeps its remediation history.

### 4.3 `prd.md` — the Parakeet lines

`prd.md:426`, OLD:

> If WhisperKit transcription is inadequate, the Parakeet-TDT alternate ASR path is the next step.

NEW:

> If WhisperKit transcription is inadequate, the first check is the decoding configuration against a retention metric, because a decoding gate removed whole windows in Epic 4 while the model was fine (`sprint-change-proposal-2026-09-21.md`); an alternate ASR path is evaluated only on evidence that expected content is absent from the transcript, through the same regression suite.

`prd.md:718`, OLD:

> - **Parakeet-TDT current MLX maturity.** Alternate ASR path if WhisperKit's quality is insufficient. Resolution: spike Parakeet-TDT on 2–3 captured meetings; compare WER and latency against WhisperKit; pick winner. Action: build-time spike before the transcription stage locks.

NEW:

> - **Alternate ASR path, conditional.** Resolved for Epic 4 on 2026-09-21: the transcription shortfall was a WhisperKit decoding gate, not model quality, and the research report under `research/` records the landscape. Parakeet-TDT is no longer reachable through Argmax's open package; the open Swift route is FluidAudio, which documents no timestamps on its ASR result. A spike runs only if a recorded full-pipeline run shows expected-item quotes absent from the transcript, and it is scored through `Tests/regression/ami/score.py` on the five AMI meetings, never by WER alone.

`prd.md:720`, OLD:

> - **Apple SpeechAnalyzer evaluation quality (fallback only; macOS 26+).** Tertiary fallback ASR. Resolution: not needed until macOS 26 is the development target and only if both WhisperKit and Parakeet prove inadequate.

NEW:

> - **Apple SpeechAnalyzer evaluation quality (fallback only; macOS 26+).** Tertiary fallback ASR. macOS 26 is now the development target. Apple positions it for long-form and distant audio; no independent meeting-audio measurement exists, it exposes no confidence scores, and its timestamp granularity is per attributed-string run. Resolution: a one-day spike through the regression suite, only under the same condition as the alternate ASR path above.

`prd.md:336`: leave the risk statement; append one sentence:

> Epic 4 found the first inadequacy to be a decoding option, not the model; the regression suite now reports dropped reference text so the two are told apart.

Rationale: the PRD is where "designed response" lives, and it now points at a
package that no longer ships the model it names.

### 4.4 `architecture.md:81` — WhisperKit entry

OLD:

> Whisper-large-v3-turbo on ANE is the locked default.

NEW:

> Whisper-large-v3-turbo on ANE is the locked default. Decoding runs with the temperature fallback off for byte-identical re-runs and, because of that, with WhisperKit's first-token log-probability gate off as well: the gate ends a window empty and relies on the fallback to retry it, so the two options are not independent (Story 4.14).

Rationale: the constraint spans two options and a future reader will see one
without the other.

### 4.5 `spec-4-1-whisperkit-transcribe-stage.md` — line 271

Append after the existing sentence:

> Revisited 2026-09-21: the fallback stays off, and the first-token gate goes with it (Story 4.14, `sprint-change-proposal-2026-09-21.md`).

Rationale: the spec told the reader Story 4.9's evidence would decide; it should
say what decided.

### 4.6 `Tests/regression/ami/README.md` and `thresholds.json`

README, under "What it measures", add:

> - Reference content words that fall in a run of 25 or more with no transcript text against them, as a fraction of the reference. Word error rate cannot stand in for this: it folds stripped fillers, substitutions and vanished windows into one number, and a decoding gate that removed a fifth of a meeting moved WER from 0.25 to 0.35 while looking like ordinary far-field error.

`thresholds.json`: add `"max_dropped_reference_fraction"`, calibrated from the
recorded rerun. On the unrecorded 2026-09-21 run under the fix the fraction is
0.0 on every meeting; a limit of 0.03 leaves the same one-item slack the other
limits carry.

Rationale: the metric is what would have caught this at Story 4.1.

### 4.7 `sprint-status.yaml`

- `story-4-13-decide-the-epic-4-exit-lever-asr-or-a-lower-floor`: status
  `done`, with a `resolution` line: "Lever: WhisperKit decoding gate, fixed in
  Story 4.14, no ASR swap. Floor: stands at 80%; Story 4.15 owns the residual.
  `sprint-change-proposal-2026-09-21.md`."
- `story-4-13-rerun-part-b-under-the-promoted-prompt`: stays `open`; append to
  the action: "Run it under Story 4.14's fix so the recorded row is the fixed
  pipeline. Unrecorded run on 2026-09-21 under the fix: 14/19 = 74%, WER 0.20 to
  0.25, false keeps 3."
- Under `epic-4`, add `4-14-retention-unset-first-token-gate-measure-dropped-text: backlog`
  and `4-15-summarizer-under-production-es2002b-es2004a: backlog` after
  `4-13-prompt-recall-pass: done`.

Rationale: the two open decisions were the trigger; both get a written outcome
where the maintainer looks for it.

---

## Section 5: Implementation handoff

**Scope:** Moderate. Backlog reorganization inside Epic 4, two new stories, one
metric, planning edits.

**Routing:**

- **Maintainer:** approve or amend this proposal; choose between the recommended
  floor position and the alternative in Section 3; apply the planning-artifact
  edits in Section 4 or delegate them.
- **Developer agent:** Story 4.14 first. The diff in the worktree is the
  starting point: `Sources/WhisperKitTranscriber/WhisperKitTranscriber.swift`
  gains one option and its doc comment;
  `Tests/WhisperKitTranscriberTests/WhisperKitSegmentMappingTests.swift` gains
  one expectation. Then the retention metric, then the recorded rerun.
- **Developer agent, after 4.14:** Story 4.15, starting from the two bench
  output directories of 2026-09-21 in the scratch bench roots, or from a fresh
  pair of runs at about $0.75.

### Success criteria

- Story 4.14: the decoding-options test pins `firstTokenLogProbThreshold == nil`;
  `score.py report` prints a dropped-text fraction per meeting; `history.jsonl`
  has a row with the promoted prompt and the fix, and `min_item_recall` is
  raised to guard it.
- Story 4.15: a written finding per reproduction, arms recorded in
  `Tests/fixtures/`, and one of the two stop conditions met.
- Epic 4: exits through Story 4.10 when a recorded full-pipeline run reaches 16
  of 19, or through the floor alternative if the maintainer chooses it, with
  the ceiling written down either way.

### What this proposal does not do

- It does not swap the ASR model or schedule a Parakeet spike. The condition
  under which one starts is written into the PRD instead.
- It does not move the floor. It recommends against moving it and states what
  moving it would give up.
- It does not commit or record anything. The regression run under the fix was
  deliberately left out of `history.jsonl` so that the recorded row comes from
  the landed story.
