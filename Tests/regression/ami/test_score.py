#!/usr/bin/env python3
"""Self-check for score.py's matching rule. No dependencies; run it directly.

The rule carries a calibrated threshold and is the only thing standing between
a prompt change and the Epic 4 number, so it needs a check that runs in CI.
`swift test` cannot reach it: it is Python.
"""
import json
import sys
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

# report() reads these; a missing one is a crash mid-run rather than a message.
for limit in ("max_wer", "max_realtime_factor", "max_cost_usd", "min_item_recall", "item_text_overlap", "max_false_keeps"):
    check(f"thresholds.json defines {limit}", limit in THRESHOLDS)


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
check("a mixed set labels its coverage", "1 of 2 rows" in text)

# A fully scored set reports the plain total with no coverage caveat.
text, ok = run_report([dict(ROW, false_keeps=1), dict(ROW, ami_id="ES0000b", false_keeps=1)])
check("a fully scored set reports a plain total", "false keeps 2/8\n" in text)

# The partial total is still a floor on the set, so it is checked.
over = THRESHOLDS["max_false_keeps"] + 1
_, ok = run_report([dict(ROW), dict(ROW, ami_id="ES0000b", false_keeps=over)])
check("a partial total over the limit still breaches", not ok)

for name in failures:
    print(f"test_score: FAILED: {name}", file=sys.stderr)
print(f"test_score: {len(failures)} failed")
sys.exit(1 if failures else 0)
