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

## Reference transcripts

ES2002a/b and ES2003a/b reuse the Epic 3 eval fixtures under `Tests/SummarizeTests/Fixtures/eval/`. ES2004a has its own reference under `reference/es2004a/`, in the same format, built with `Tests/scripts/eval_fixture_tool.py`. It lives here so that adding a meeting to this suite does not add a fixture to the Epic 3 eval harness, which runs every directory under `eval/` on every `swift test`.

## Epic 4 exit criteria

The five meetings also serve as the recording set for `Tests/scripts/run-epic4-exit-criteria.sh`, which needs at least five recordings and at least two with four or more attendees.

```bash
AURICLE_EXIT_FIXTURES=$(Tests/regression/ami/prepare-exit-fixtures.sh) Tests/scripts/run-epic4-exit-criteria.sh
```

`prepare-exit-fixtures.sh` writes a temporary directory and prints its path. For each meeting it makes a symlink to the cached audio and an expected file in the format that script's header documents. It omits `speakers`, so the run uses `--publish-anyway`.

The expected quotes are the reference transcript's wording, and the pipeline transcribes the audio itself. An expected item only survives when the transcription reproduces that wording, so the pass rate reflects word error rate as much as summarization.

## Comparing models

The transcriber, diarizer and summarizer models are the ones the CLI ships with. Each row in `history.jsonl` records them, so a model change appears as a new row next to the old ones. Selecting a model at run time is not supported.

## Not covered

- No 1:1 recording: every AMI scenario meeting has four speakers.
- Speaker names are not scored, only the speaker count.

The audio is not in the repository. `fetch.sh` downloads it into `~/Library/Caches/auricle-ami` and checks each file against `manifest.json`. See `NOTICE.md` for the licence.
