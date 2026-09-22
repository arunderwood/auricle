# AMI regression suite

Runs five public AMI meetings (ES2002a/b, ES2003a/b, ES2004a) through the real CLI pipeline and scores the result. It uses the real models and spends Anthropic credit, so it is run by hand, never in CI.

```bash
Tests/regression/ami/run.sh                      # all five
Tests/regression/ami/run.sh ES2003a              # one
AURICLE_AMI_RECORD=1 Tests/regression/ami/run.sh # also append to history.jsonl
```

Setup is the same as `Tests/scripts/run-epic4-exit-criteria.sh`: launch the app once, set `vault_path` in `~/.auricle/config.toml` (use a scratch vault; every run publishes notes), and keep an Anthropic key in the Keychain.

## What it measures

- Word error rate against the meeting's reference transcript. Each meeting's `reference` in `manifest.json` names the directory that holds it.
- Transcription time over audio length (realtime factor).
- Speakers the diarizer found, against 4.
- Grounded items kept, dropped items, and cost.
- How many of the 19 expected items the note recalls, and how many kept items match no expected item at all (false keeps).
- Reference content words that fall in a run of 25 or more with no transcript text against them, as a count and a fraction of the reference. Word error rate cannot stand in for this: it folds stripped fillers, substitutions and vanished windows into one number, and a decoding gate that removed a fifth of a meeting moved WER from 0.25 to 0.35 while looking like ordinary far-field error.

## How an item is matched

An expected item counts as recalled on either of two tests, inside its own section heading:

- its reference quote overlaps a note block quote by at least `RECALL_OVERLAP` of the shorter side's words, or
- its `text` overlaps a kept item's own bullet text by at least `item_text_overlap`.

The second test exists because the first one asks whether the model picked the same sentence a human curator picked, not whether the item survived. A correct item supported by a different sentence of the same discussion scores zero on the quote test alone. A kept item that fails both tests against every expected item in its section is a false keep, so a recall gain bought with items nobody asked for shows up as a rising false-keep count instead of passing unobserved.

`score.py` holds the only implementation of this rule. `Tests/scripts/run-epic4-exit-criteria.sh` imports it rather than carrying its own, because two copies is how the two scripts came to report different numbers for the same notes.

`thresholds.json` holds the limits. They guard against a regression from the recorded baseline. They are not quality targets. Change a limit only with a reason in the commit message.

`item_text_overlap` is 0.55. It was calibrated on the five notes of the 2026-09-21 exit run by labelling every expected/kept pair same-item or not: the highest scoring non-pair reaches 0.526, and the lowest scoring same-item pair that the quote test misses reaches 0.583. Both margins are about 0.03 over 15 kept items, so it is a working threshold, not a law.

`max_false_keeps` is 6 against a re-scored baseline of 4: one item is 6.7 percentage points at this set size, so a tight bound would fire on noise. `min_item_recall` carries the same one-item margin below its own baseline; see below for the number and why it is a median of three runs, not one.

`max_dropped_reference_fraction` is 0.03. WhisperKit's `decodeOptions` used to end a 30-second window empty whenever the first sampled token's log-probability fell under -1.5, and relied on a temperature fallback the app disables to retry it; with no fallback the window was seeked past and its speech never reached the transcript. On the five meetings this held between 11% and 19% of the reference in true drops (14%, 14%, 18%, 11%, 19%; `sprint-change-proposal-2026-09-21.md`, Section 1). Unsetting the gate (`WhisperKitTranscriber.decodeOptions`) took every meeting to 0.0% dropped on the run that fixed it, so 0.03 leaves the same one-item-scale slack the other limits carry rather than asserting the fix produces exactly zero forever.

The summarization call sets no `temperature` (`claude-opus-5` accepts none), so item recall is not reproducible between full-pipeline runs of the same code: three recorded runs of the promoted prompt under the unset first-token gate scored 58% (11/19), 74% (14/19) and 84% (16/19) of the same 19 expected items. A gate calibrated on one such draw is calibrated on noise. `report` instead groups `history.jsonl` into runs (rows sharing a `run_at` and `revision`, every meeting present) and gates item recall, false keeps and dropped reference fraction on the median of the three newest complete runs sharing the newest revision. A run's `revision` is the last commit that touched `Sources`/`App`, not plain `HEAD`, so a docs or test-script commit between two runs of the same pipeline binary cannot fragment them into different revisions. Older runs, and runs at an earlier revision, still print in the per-meeting table for context; naming a single meeting on the command line checks it against a limit calibrated for the five-meeting set, not the one meeting. Fewer than three complete runs at the newest revision prints as not yet gated, never as a pass.

`min_item_recall` is 0.68. The three runs above are revision `21a5771be6f33b3186ab7613de15c27a32c352e5`'s first three, median 74% (14/19). `min_item_recall` sits one item below that median, the same margin `max_false_keeps` carries above its own baseline: 13/19 = 0.6842, rounded down to 0.68.

The rows already in `history.jsonl` from before 2026-09-22 were scored before the second test existed and carry no false-keep count, so their recall numbers are not comparable with anything recorded after it. The 2026-09-22 run recorded above re-establishes the baseline; it is the first to carry a false-keep count and a dropped-reference-fraction together. `report` prints `-` for a row missing either key and leaves it out of the corresponding aggregate and gate rather than showing it as zero: a zero would assert a count nobody took, and would satisfy `max_false_keeps` on the strength of it. Do not backfill the earlier rows.

`scripts/check.sh lint` runs `report` over `history.jsonl` on every build. That file is the only committed corpus of real result rows, and its rows were written by older scorers, so it is what a scorer change breaks first. The run asserts that the formatter and the thresholds survive real data; it is not a quality assertion, since the rows mix revisions.

## Reference transcripts

ES2002a/b and ES2003a/b reuse the Epic 3 eval fixtures under `Tests/SummarizeTests/Fixtures/eval/`. ES2004a has its own reference under `reference/es2004a/`, in the same format, built with `Tests/scripts/eval_fixture_tool.py`. It lives here so that adding a meeting to this suite does not add a fixture to the Epic 3 eval harness, which runs every directory under `eval/` on every `swift test`.

## The offline recall bench

`score.py` has a second consumer. `score.py note <note-path> <expected-json> <transcript-json>` scores one note on its own: it reads no database, no cache root and no manifest, and prints `kept_items`, `ungrounded_quotes`, `expected_items`, `recalled_items` and `false_keeps` as one JSON object. It takes the item-text threshold from the `thresholds.json` beside it, so it applies the same two tests `meeting` does. `score.py meeting` prints the same five keys, from the same `score_note`, so the matching rule has one home and the two consumers cannot drift; `test_score.py` pins that agreement.

`Tests/scripts/run-recall-bench.sh` is the caller. It summarizes the reference transcripts this manifest names — no audio, no WhisperKit, no state database, no vault — renders each result through the shipped note path, and scores it. That makes a prompt change measurable in about two minutes and under $0.30 per arm, without a full pipeline run.

```bash
Tests/scripts/run-recall-bench.sh                                          # the shipped pair of arms
Tests/scripts/run-recall-bench.sh --arm substring --arm substring:/abs/dir # one prompt set against another
```

Its `ungrounded_quotes` is a stronger check than the full pipeline's: with no transcription in the loop, the note's quotes are sliced from this same reference transcript, so a non-zero count is a grounding defect rather than a word-error artifact.

The bench does not replace a full run. It holds transcription and diarization fixed at human-reference quality, so its recall is an upper bound on what the pipeline scores end to end.

## Epic 4 exit criteria

The five meetings also serve as the recording set for `Tests/scripts/run-epic4-exit-criteria.sh`, which needs at least five recordings and at least two with four or more attendees.

```bash
AURICLE_EXIT_FIXTURES=$(Tests/regression/ami/prepare-exit-fixtures.sh) Tests/scripts/run-epic4-exit-criteria.sh
```

`prepare-exit-fixtures.sh` writes a temporary directory and prints its path. For each meeting it makes a symlink to the cached audio and an expected file in the format that script's header documents. It omits `speakers`, so the run uses `--publish-anyway`.

Each expected item carries the reference quote and the reference item text verbatim. The exit script scores them through `score.py`, so its pass rate and the suite's item recall are the same measurement over the same notes. Word overlap is what makes the verbatim quote usable: the note's block quote comes from the pipeline's own transcription while the reference quote is a separate human transcript of the same speech, at a word error rate of 0.28 to 0.35, so an exact match over a 7 to 24 word run effectively never happens.

The exit script prints its false-keep count but does not gate on it. `epics.md` Story 4.10 defines the exit criteria as the pass rate and the cost ceiling; `score.py report` is where the false-keep limit is enforced.

AMI is the Epic 4 acceptance corpus. The repository is public and recordings, transcripts and titles are never committed, so a private corpus cannot gate a build: nothing built from it is reproducible by anyone reading the repo. AMI is harder than the target workload — far-field, four speakers, word error rate 0.28 to 0.38, against a laptop call on a headset — so 80% here is a conservative floor rather than an equivalent one.

## Comparing models

The transcriber, diarizer and summarizer models are the ones the CLI ships with. Each row in `history.jsonl` records them, so a model change appears as a new row next to the old ones. Selecting a model at run time is not supported.

## Not covered

- No 1:1 recording: every AMI scenario meeting has four speakers.
- Speaker names are not scored, only the speaker count.

The audio is not in the repository. `fetch.sh` downloads it into `~/Library/Caches/auricle-ami` and checks each file against `manifest.json`. See `NOTICE.md` for the licence.
