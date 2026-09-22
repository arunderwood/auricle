#!/usr/bin/env python3
"""Self-check for score.py's matching rule. No dependencies; run it directly.

The rule carries a calibrated threshold and is the only thing standing between
a prompt change and the Epic 4 number, so it needs a check that runs in CI.
`swift test` cannot reach it: it is Python.
"""
import inspect
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import score

HERE = Path(__file__).parent
THRESHOLDS = json.loads((HERE / "thresholds.json").read_text(encoding="utf-8"))
ITEM_TEXT_OVERLAP = THRESHOLDS["item_text_overlap"]

failures = []


def check(name, condition):
    if not condition:
        failures.append(name)


def note(*bullets):
    """A note body with the given (section, text, quote) bullets."""
    sections = {"Action Items": [], "Decisions": []}
    for section, text, quote in bullets:
        body = "\n".join(f"  > {line}" for line in quote.split("\n"))
        sections[section].append(f"- {text}\n{body}")
    return "\n\n".join(
        f"## {name}\n\n" + "\n".join(items) if items else f"## {name}"
        for name, items in sections.items()
    )


# note_items: a bullet's own text is kept, and a quote may span several lines.
parsed = score.note_items(
    note(
        ("Action Items", "Marketing will do trend watching.", "and marketing you're gonna be\nthinking about trend watching."),
        ("Decisions", "Stay with regular batteries.", "Okay, so just stick to to regular"),
    )
)
check("note_items keeps the bullet text", parsed["Action Items"][0]["text"] == "Marketing will do trend watching.")
check(
    "note_items joins a multi-line quote",
    parsed["Action Items"][0]["quote"] == "and marketing you're gonna be\nthinking about trend watching.",
)
check("note_items assigns bullets to their section", len(parsed["Decisions"]) == 1)
check("note_items ignores text outside the two sections", sum(len(v) for v in parsed.values()) == 2)

# Same passage: the quote test alone is enough.
same_passage = {
    "text": "Marketing will do trend watching for the next working session.",
    "quote": "and marketing you're gonna be thinking about trend watching.",
}
kept_same_passage = {
    "text": "The marketing role is to watch trends before the next session.",
    "quote": "and marketing you're gonna be thinking about trend watching",
}
check("same passage matches", score.matches(same_passage, kept_same_passage, ITEM_TEXT_OVERLAP))

# Same item, different passage: the quote test fails and the text test carries it.
different_passage = {
    "text": "The LCD will be black and white rather than colour, to keep unit cost down.",
    "quote": "most of the mobile phone displays you see these days are colour but we should probably try to stick to black and white.",
}
kept_different_passage = {
    "text": "The team agreed the LCD display will be black and white rather than colour in order to keep the unit cost down.",
    "quote": "I would agree. Simply to keep the unit cost down.",
}
check(
    "the quote test alone misses the same item in another passage",
    score.overlap(different_passage["quote"], kept_different_passage["quote"]) < score.RECALL_OVERLAP,
)
check("same item in another passage matches", score.matches(different_passage, kept_different_passage, ITEM_TEXT_OVERLAP))

# A kept item that is neither: a false keep.
unrelated = {
    "text": "The group decided to treat teletext as obsolete and not support it on the remote.",
    "quote": "The teletext we're gambling with and we're going to say it's dead.",
}
check("an unrelated kept item matches nothing", not score.matches(different_passage, unrelated, ITEM_TEXT_OVERLAP))
check("an unrelated kept item matches nothing either way", not score.matches(same_passage, unrelated, ITEM_TEXT_OVERLAP))

# An expected item with no `text` falls back to the quote test alone.
no_text = {"quote": same_passage["quote"]}
check("an expected item without text still matches on its quote", score.matches(no_text, kept_same_passage, ITEM_TEXT_OVERLAP))
check("an expected item without text does not match on text", not score.matches(no_text, unrelated, ITEM_TEXT_OVERLAP))

# A quote under four words never counts; the text test can still carry the item.
short_quote = {"text": kept_different_passage["text"], "quote": "black and white"}
check("a quote under four words scores zero", score.overlap(different_passage["quote"], short_quote["quote"]) == 0.0)
check("a short quote does not stop the text test", score.matches(different_passage, short_quote, ITEM_TEXT_OVERLAP))

# Calibration window, from the 2026-09-21 run: the highest scoring non-pair
# reached 0.526 and the lowest scoring same-item pair the quote test missed
# reached 0.583. A threshold outside that window changes the recorded baseline.
check("item_text_overlap stays above the highest non-pair", ITEM_TEXT_OVERLAP > 0.526)
check("item_text_overlap stays at or below the weakest same-item pair", ITEM_TEXT_OVERLAP <= 0.583)

# score_note is the one function `meeting`, `note` and the bench all reach, so
# the two-test rule has to survive the trip through it and through the `note`
# subcommand's JSON. A revert of the bench to quote-only matching fails here.
scored_note = note(
    ("Decisions", kept_different_passage["text"], kept_different_passage["quote"]),
    ("Action Items", unrelated["text"], unrelated["quote"]),
)
expected_file = {"action_items": [], "decisions": [different_passage]}
scored = score.score_note(scored_note, scored_note, expected_file, ITEM_TEXT_OVERLAP)
check("score_note recalls an item the quote test alone would miss", scored["recalled_items"] == 1)
check("score_note counts the unmatched keep as a false keep", scored["false_keeps"] == 1)
check("score_note counts every bullet as kept", scored["kept_items"] == 2)
check("score_note reports the expected total", scored["expected_items"] == 1)
check(
    "quote-only matching would have scored this zero",
    not any(
        score.overlap(different_passage["quote"], k["quote"]) >= score.RECALL_OVERLAP
        for k in score.note_items(scored_note)["Decisions"]
    ),
)

# The `note` subcommand prints exactly what score_note returned, under the
# threshold beside this script, so the Swift bench decodes the same numbers
# `meeting` records.
with tempfile.TemporaryDirectory() as scratch:
    scratch = Path(scratch)
    (scratch / "note.md").write_text(scored_note, encoding="utf-8")
    (scratch / "expected.json").write_text(json.dumps(expected_file), encoding="utf-8")
    (scratch / "transcript.json").write_text(json.dumps({"text": scored_note}), encoding="utf-8")
    printed = subprocess.run(
        [sys.executable, str(HERE / "score.py"), "note", str(scratch / "note.md"), str(scratch / "expected.json"), str(scratch / "transcript.json")],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    check("the note subcommand prints what score_note returned", json.loads(printed) == scored)
    check(
        "the note subcommand reports every key the bench decodes",
        set(json.loads(printed)) == {
            "kept_items", "ungrounded_quotes", "expected_items", "recalled_items", "false_keeps",
            "kept_action_items", "expected_action_items", "recalled_action_items", "false_keep_action_items",
            "kept_decisions", "expected_decisions", "recalled_decisions", "false_keep_decisions",
        },
    )
    check("the note subcommand uses the recorded item-text threshold", score.thresholds_beside_this_script()["item_text_overlap"] == ITEM_TEXT_OVERLAP)

# `meeting` and `note` must not be able to apply the same rule at two different
# thresholds. Both read `thresholds_beside_this_script`, so a repo_root pointing
# somewhere else cannot move one of them: the source text of `meeting` must not
# resolve a thresholds path out of its repo_root argument.
meeting_source = inspect.getsource(score.meeting)
check(
    "meeting takes the item-text threshold from beside the script",
    'item_text_overlap = thresholds_beside_this_script()["item_text_overlap"]' in meeting_source,
)
check("meeting does not resolve a thresholds path from repo_root", "thresholds.json" not in meeting_source)


# `report` is the last surface where a caller-supplied file could disagree with
# the rule the rows were scored by. A file that redefines item_text_overlap is
# refused, one that omits it only sets gates and is fine, and neither case may
# depend on the gates themselves.
def run_report(limits, rows):
    with tempfile.TemporaryDirectory() as scratch:
        scratch = Path(scratch)
        (scratch / "thresholds.json").write_text(json.dumps(limits), encoding="utf-8")
        (scratch / "results.jsonl").write_text("\n".join(json.dumps(r) for r in rows), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(HERE / "score.py"), "report", str(scratch / "thresholds.json"), str(scratch / "results.jsonl")],
            capture_output=True,
            text=True,
        )


gates_only = {
    k: THRESHOLDS[k]
    for k in ("max_wer", "max_realtime_factor", "max_cost_usd", "min_item_recall", "max_false_keeps", "max_dropped_reference_fraction")
}
clean_row = {
    "ami_id": "ES0000a", "state": "awaiting_verification", "verified_at_null": True,
    "wer": 0.1, "realtime_factor": 0.1, "cost_usd": 0.01, "ungrounded_quotes": 0,
    "diarized_speakers": 4, "expected_speakers": 4, "drop_count": 0,
    "kept_items": 1, "expected_items": 1, "recalled_items": 1, "false_keeps": 0,
}

omitted = run_report(gates_only, [clean_row])
check("report accepts a thresholds file that only sets gates", omitted.returncode == 0)

agreeing = run_report({**gates_only, "item_text_overlap": ITEM_TEXT_OVERLAP}, [clean_row])
check("report accepts a thresholds file that agrees on the rule", agreeing.returncode == 0)

disagreeing = run_report({**gates_only, "item_text_overlap": ITEM_TEXT_OVERLAP + 0.1}, [clean_row])
check("report refuses a thresholds file that redefines the rule", disagreeing.returncode != 0)
check("the refusal names both thresholds", str(ITEM_TEXT_OVERLAP) in disagreeing.stderr and str(ITEM_TEXT_OVERLAP + 0.1) in disagreeing.stderr)
check("the refusal keeps the gates argument meaningful", "drop the key" in disagreeing.stderr)


# report() reads these; a missing one is a crash mid-run rather than a message.
for limit in (
    "max_wer",
    "max_realtime_factor",
    "max_cost_usd",
    "min_item_recall",
    "item_text_overlap",
    "max_false_keeps",
    "max_dropped_reference_fraction",
):
    check(f"thresholds.json defines {limit}", limit in THRESHOLDS)


# align: the same DP wer() scores must also say which reference words the
# cheapest path deleted, so dropped_reference_words never runs a second,
# heuristic alignment over the same two sequences.
identical = [f"r{i}" for i in range(10)]
check("align finds no distance for identical sequences", score.align(identical, identical)[0] == 0)
check("align finds no deletions for identical sequences", not any(score.align(identical, identical)[1]))

reference_60 = [f"r{i}" for i in range(60)]

# A run of exactly 25 missing reference words, with matching context on both
# sides so the alignment cannot place the deletion anywhere else.
hypothesis_25_gap = reference_60[:10] + reference_60[35:]
_, deleted_25 = score.align(reference_60, hypothesis_25_gap)
check("a 25-word gap is deleted end to end", all(deleted_25[10:35]))
check("a 25-word gap touches nothing outside it", not any(deleted_25[:10]) and not any(deleted_25[35:]))
check("dropped_reference_words counts a run of exactly 25", score.dropped_reference_words(deleted_25) == 25)

# One word short of the floor: the same shape, one word narrower.
hypothesis_24_gap = reference_60[:10] + reference_60[34:]
_, deleted_24 = score.align(reference_60, hypothesis_24_gap)
check("dropped_reference_words does not count a run of 24", score.dropped_reference_words(deleted_24) == 0)

# Two separate runs of 25+ in one meeting: both lengths sum into one count.
reference_100 = [f"r{i}" for i in range(100)]
hypothesis_two_gaps = reference_100[:10] + reference_100[35:40] + reference_100[70:]
_, deleted_two_gaps = score.align(reference_100, hypothesis_two_gaps)
check("two separate 25+ runs both count", score.dropped_reference_words(deleted_two_gaps) == 25 + 30)

# A fully dropped hypothesis: the whole reference is one run.
_, deleted_all = score.align(reference_60, [])
check("an empty hypothesis deletes the whole reference", all(deleted_all))
check("dropped_reference_words counts the whole reference when it's 25 or more", score.dropped_reference_words(deleted_all) == len(reference_60))

# Below the floor even when everything is dropped: no run reaches 25.
reference_10 = [f"r{i}" for i in range(10)]
_, deleted_short = score.align(reference_10, [])
check("a fully dropped reference under 25 words counts nothing", score.dropped_reference_words(deleted_short) == 0)

# wer() must still agree with align()'s own distance: it is the same DP, not a
# second one that happens to produce compatible deletions.
check("wer matches align's distance over the reference length", score.wer(reference_60, hypothesis_25_gap) == 25 / len(reference_60))

# A hypothesis word absent from the reference takes the "left" backtrace
# branch on its own; deleted must stay empty rather than charging the
# insertion against some reference word.
reference_ins = ["a", "b", "c"]
hypothesis_ins = ["a", "x", "b", "c"]
distance_ins, deleted_ins = score.align(reference_ins, hypothesis_ins)
check("align charges one edit for a single inserted word", distance_ins == 1)
check("align marks no reference-side deletions for a pure insertion", not any(deleted_ins))

# Insertion and a true deletion together, far enough apart that substitution
# is never cheaper: deleted must ignore the inserted word and mark only the
# reference word the hypothesis actually drops.
reference_mixed = ["a", "b", "c", "d", "e", "f"]
hypothesis_mixed = ["a", "x", "b", "c", "d", "f"]
distance_mixed, deleted_mixed = score.align(reference_mixed, hypothesis_mixed)
check("align counts an insertion plus a deletion as two edits", distance_mixed == 2)
check(
    "align marks only the dropped reference word as deleted, not the inserted one",
    deleted_mixed == [False, False, False, False, True, False],
)

# meeting() wires align()'s deletions into dropped_reference_words and
# dropped_reference_fraction through dropped_stats; test that wiring directly,
# with an independently computed expectation, rather than only its two pieces.
dropped_synth, fraction_synth = score.dropped_stats(deleted_25, len(reference_60))
check("dropped_stats returns the dropped-word count align/dropped_reference_words agree on", dropped_synth == 25)
check("dropped_stats divides by the reference length, not some other total", fraction_synth == 25 / len(reference_60))

dropped_none, fraction_none = score.dropped_stats([False] * 10, 10)
check("dropped_stats returns zero count and fraction for no deletions", dropped_none == 0 and fraction_none == 0.0)

dropped_empty, fraction_empty = score.dropped_stats([], 0)
check("dropped_stats does not divide by zero for an empty reference", fraction_empty == 0.0)


def run_report(rows):
    """report() over the given rows: its stdout, and whether it exited 0."""
    import contextlib
    import io
    import tempfile

    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")
        path = handle.name
    out = io.StringIO()
    try:
        # report() writes breaches to stderr; swallow them so a deliberate
        # breach below does not read as this self-check failing.
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            score.report(str(HERE / "thresholds.json"), path)
    except SystemExit as exit_code:
        return out.getvalue(), exit_code.code == 0
    finally:
        Path(path).unlink()
    return out.getvalue(), True


ROW = {
    "ami_id": "ES0000a", "state": "awaiting_verification", "verified_at_null": True,
    "wer": 0.30, "realtime_factor": 0.05, "diarized_speakers": 4, "expected_speakers": 4,
    "kept_items": 4, "drop_count": 0, "recalled_items": 3, "expected_items": 3,
    "ungrounded_quotes": 0, "cost_usd": 0.05,
}

# A row from before false keeps were counted must not crash the report, and must
# not be reported as a clean zero: that would satisfy max_false_keeps on a
# measurement nobody took.
text, ok = run_report([dict(ROW)])
check("a row without false_keeps does not crash report", ok)
check("an unmeasured row is not counted as zero false keeps", "false keeps 0/" not in text)
check("an all-unmeasured set says so", "not measured" in text)

# A mix reports the partial total and says how much of the set it covers.
text, ok = run_report([dict(ROW), dict(ROW, ami_id="ES0000b", false_keeps=1)])
check("a mixed set still exits 0 inside the limit", ok)
check("a mixed set reports its partial total", "false keeps 1/4" in text)
check("a mixed set labels its coverage", "1 of 2 newest-run rows" in text)

# A fully scored set reports the plain total with no coverage caveat.
text, ok = run_report([dict(ROW, false_keeps=1), dict(ROW, ami_id="ES0000b", false_keeps=1)])
check("a fully scored set reports a plain total", "false keeps 2/8\n" in text)

# The partial total is still a floor on the set, so it is checked.
over = THRESHOLDS["max_false_keeps"] + 1
_, ok = run_report([dict(ROW), dict(ROW, ami_id="ES0000b", false_keeps=over)])
check("a partial total over the limit still breaches", not ok)

# report(): dropped_reference_fraction follows the same "-" convention as
# false_keeps for a row that predates the metric, and is enforced once present.
ROW_WITH_DROP = {**ROW, "dropped_reference_fraction": 0.0, "dropped_reference_words": 0}

text, ok = run_report([dict(ROW)])
check("a row without dropped_reference_fraction does not crash report", ok)
check("an unmeasured dropped-reference row is not printed as 0.0%", "0.0%" not in text)

text, ok = run_report([dict(ROW_WITH_DROP)])
check("a row within the dropped-reference limit does not breach", ok)
check("a measured dropped-reference row prints its fraction", "0.0%" in text)

over_drop = THRESHOLDS["max_dropped_reference_fraction"] + 0.01
_, ok = run_report([dict(ROW_WITH_DROP, dropped_reference_fraction=over_drop)])
check("a dropped-reference fraction over the limit breaches", not ok)

for name in failures:
    print(f"test_score: FAILED: {name}", file=sys.stderr)
print(f"test_score: {len(failures)} failed")
sys.exit(1 if failures else 0)


# The summarizer under-produces action items and over-produces decisions, so a
# total can stay flat while the sections move in opposite directions. These pin
# that the split is reported and that it is consistent with the totals.
NOTE_SPLIT = """## Action Items

## Decisions

- The team will target the fifteen to thirty five age bracket.
  > aiming the product at the fifteen to thirty five age bracket
- Something nobody decided at all.
  > a passage that matches no expected item whatsoever here
"""
EXPECTED_SPLIT = {
    "action_items": [
        {"text": "Marketing will do trend watching before the next session.", "quote": "and marketing you're gonna be thinking about trend watching"},
    ],
    "decisions": [
        {"text": "Target the product at the fifteen to thirty five age bracket.", "quote": "aiming the product at the fifteen to thirty five age bracket"},
    ],
}
split = score.score_note(NOTE_SPLIT, NOTE_SPLIT, EXPECTED_SPLIT, ITEM_TEXT_OVERLAP)
check("a section that produced nothing recalls nothing", split["recalled_action_items"] == 0)
check("the empty section still reports its expected count", split["expected_action_items"] == 1)
check("the other section recalls its item", split["recalled_decisions"] == 1)
check("the unmatched decision is a false keep in its own section", split["false_keep_decisions"] == 1)
check("no false keep is attributed to the empty section", split["false_keep_action_items"] == 0)
check(
    "the per-section recalled counts sum to the total",
    split["recalled_action_items"] + split["recalled_decisions"] == split["recalled_items"],
)
check(
    "the per-section false keeps sum to the total",
    split["false_keep_action_items"] + split["false_keep_decisions"] == split["false_keeps"],
)
check(
    "the per-section kept counts sum to the total",
    split["kept_action_items"] + split["kept_decisions"] == split["kept_items"],
)
check(
    "the per-section expected counts sum to the total",
    split["expected_action_items"] + split["expected_decisions"] == split["expected_items"],
)
