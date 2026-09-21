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

## How an item is matched

An expected item counts as recalled on either of two tests, inside its own section heading:

- its reference quote overlaps a note block quote by at least `RECALL_OVERLAP` of the shorter side's words, or
- its `text` overlaps a kept item's own bullet text by at least `item_text_overlap`.

The second test exists because the first one asks whether the model picked the same sentence a human curator picked, not whether the item survived. A correct item supported by a different sentence of the same discussion scores zero on the quote test alone. A kept item that fails both tests against every expected item in its section is a false keep, so a recall gain bought with items nobody asked for shows up as a rising false-keep count instead of passing unobserved.

`score.py` holds the only implementation of this rule. `Tests/scripts/run-epic4-exit-criteria.sh` imports it rather than carrying its own, because two copies is how the two scripts came to report different numbers for the same notes.

`thresholds.json` holds the limits. They guard against a regression from the recorded baseline. They are not quality targets. Change a limit only with a reason in the commit message.

`item_text_overlap` is 0.55. It was calibrated on the five notes of the 2026-09-21 exit run by labelling every expected/kept pair same-item or not: the highest scoring non-pair reaches 0.526, and the lowest scoring same-item pair that the quote test misses reaches 0.583. Both margins are about 0.03 over 15 kept items, so it is a working threshold, not a law.

`max_false_keeps` is 6 against a re-scored baseline of 4. `min_item_recall` sits below its baseline and `max_false_keeps` above its own, for the same reason: one item is 6.7 percentage points at this set size, so a tight bound would fire on noise.

The report aggregates over the meetings in one invocation, and `min_item_recall` is calibrated for the whole set: on the re-scored 2026-09-21 notes recall runs 58% across all five but 50% on ES2002b, 75% on ES2003b and 0% on ES2004a. Naming a single meeting on the command line therefore checks it against a limit it was never meant to clear on its own. Read a one-meeting run for its WER, realtime factor and cost, and judge recall from a full run.

The rows already in `history.jsonl` were scored before the second test existed and carry no false-keep count, so their recall numbers are not comparable with anything recorded after it. The next full run re-establishes the baseline.

## Reference transcripts

ES2002a/b and ES2003a/b reuse the Epic 3 eval fixtures under `Tests/SummarizeTests/Fixtures/eval/`. ES2004a has its own reference under `reference/es2004a/`, in the same format, built with `Tests/scripts/eval_fixture_tool.py`. It lives here so that adding a meeting to this suite does not add a fixture to the Epic 3 eval harness, which runs every directory under `eval/` on every `swift test`.

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
