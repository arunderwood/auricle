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
- How many expected items the note recalls. Recall is coarse: 19 expected items in total, matched by word overlap with the model's quote.

`thresholds.json` holds the limits. They guard against a regression from the recorded baseline in `history.jsonl`. They are not quality targets. Change a limit only with a reason in the commit message.

The report aggregates over the meetings in one invocation, and `min_item_recall` is calibrated for the whole set: recall runs 42% across all five but only 25% on ES2002b and ES2003b and 33% on ES2004a. Naming a single meeting on the command line therefore checks it against a limit it was never meant to clear on its own. Read a one-meeting run for its WER, realtime factor and cost, and judge recall from a full run.

## Reference transcripts

ES2002a/b and ES2003a/b reuse the Epic 3 eval fixtures under `Tests/SummarizeTests/Fixtures/eval/`. ES2004a has its own reference under `reference/es2004a/`, in the same format, built with `Tests/scripts/eval_fixture_tool.py`. It lives here so that adding a meeting to this suite does not add a fixture to the Epic 3 eval harness, which runs every directory under `eval/` on every `swift test`.

## Epic 4 exit criteria

The five meetings also serve as the recording set for `Tests/scripts/run-epic4-exit-criteria.sh`, which needs at least five recordings and at least two with four or more attendees.

```bash
AURICLE_EXIT_FIXTURES=$(Tests/regression/ami/prepare-exit-fixtures.sh) Tests/scripts/run-epic4-exit-criteria.sh
```

`prepare-exit-fixtures.sh` writes a temporary directory and prints its path. For each meeting it makes a symlink to the cached audio and an expected file in the format that script's header documents. It omits `speakers`, so the run uses `--publish-anyway`.

Each expected item's quote is a short match fragment from `exit-fragments.json`, not the reference quote. The exit script decides that an item survived by testing whether the expected quote is a substring of the note's block quote, and that block quote comes from the pipeline's own transcription. The reference quotes are a separate human transcript of the same speech, 7 to 24 words long, and word error rate runs 0.28 to 0.35, so an exact match over a run that long effectively never happens. Matching on the full reference quote scores near zero regardless of how good the summary is.

A fragment is a contiguous run of its reference quote, four to seven words, chosen to survive a different transcriber: no fillers, no stutters, no sentence punctuation, no digits, no spelled-out letters like `L_E_D_`, and no word whose British and American spellings differ. `prepare-exit-fixtures.sh` checks that every reference item has a fragment and that each fragment really is a substring of its quote, so a reference edit that invalidates a fragment fails the build instead of quietly scoring zero.

The tradeoff is precision: a short fragment can match a block quote about something else, which counts an item as surviving when it did not. That inflates the pass rate rather than deflating it, so read a fragment score as an upper bound and `score.py`'s item recall as the acceptance number.

AMI is the Epic 4 acceptance corpus. The repository is public and recordings, transcripts and titles are never committed, so a private corpus cannot gate a build: nothing built from it is reproducible by anyone reading the repo. AMI is harder than the target workload — far-field, four speakers, word error rate 0.28 to 0.38, against a laptop call on a headset — so 80% here is a conservative floor rather than an equivalent one.

## Comparing models

The transcriber, diarizer and summarizer models are the ones the CLI ships with. Each row in `history.jsonl` records them, so a model change appears as a new row next to the old ones. Selecting a model at run time is not supported.

## Not covered

- No 1:1 recording: every AMI scenario meeting has four speakers.
- Speaker names are not scored, only the speaker count.

The audio is not in the repository. `fetch.sh` downloads it into `~/Library/Caches/auricle-ami` and checks each file against `manifest.json`. See `NOTICE.md` for the licence.
