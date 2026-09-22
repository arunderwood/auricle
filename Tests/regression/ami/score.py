#!/usr/bin/env python3
"""Scores one pipeline run against its AMI reference, and reports a run.

  score.py meeting <meeting-id> <ami-id> <db> <cache-root> <repo-root>
      Prints one JSON object of numbers. Reads the note, the cached transcript
      and diarization, and the state database. Prints no transcript text.
  score.py note <note-path> <expected-json> <transcript-json>
      Prints one JSON object of note scores, under the same two tests. Reads
      nothing else: no database, no cache root, no manifest. Takes the
      item-text threshold from the thresholds.json beside this script. The
      offline recall bench calls this.
  score.py report <thresholds.json> <results.jsonl>
      Prints a table, checks the thresholds, exits 1 on a breach.

An expected item survives on either of two tests: its quote overlaps a note
block quote, or its `text` overlaps a kept item's text. A kept item that
survives neither test against any expected item is a false keep.
"""
import json
import re
import sqlite3
import statistics
import sys
from pathlib import Path

FILLERS = {"um", "uh", "uhm", "mm", "hmm", "mhm", "mm-hmm", "erm", "ah", "er"}
RECALL_OVERLAP = 0.5
MIN_QUOTE_WORDS = 4


def words(text):
    text = re.sub(r"(?m)^Speaker_\d+:\s*", "", text).lower()
    text = re.sub(r"[^a-z0-9' -]", " ", text).replace("-", " ")
    return [w for w in text.split() if w not in FILLERS]


def align(reference, hypothesis):
    """Word-level Levenshtein alignment: edit distance, plus which reference
    words the cheapest path deleted (present in reference, absent from
    hypothesis).

    One DP over the same two sequences `wer()` always aligned, now keeping a
    direction per cell so the alignment can be walked back instead of only
    scored. Directions pack into a flat `bytearray` (0 = diagonal, match or
    substitution; 1 = up, a reference word with no hypothesis counterpart;
    2 = left, a hypothesis word with no reference counterpart) rather than a
    grid of Python objects, because the largest AMI meeting is ~6,600 words a
    side: a (n+1)x(m+1) table of ints would run to hundreds of MB, while one
    byte per cell keeps it to tens.
    """
    n, m = len(reference), len(hypothesis)
    width = m + 1
    directions = bytearray((n + 1) * width)
    for j in range(1, width):
        directions[j] = 2  # row 0: hypothesis word j has no reference counterpart.
    previous = list(range(width))
    for i in range(1, n + 1):
        current = [i] + [0] * m
        directions[i * width] = 1  # column 0: reference word i has no hypothesis counterpart.
        ref_word = reference[i - 1]
        for j in range(1, width):
            diagonal = previous[j - 1] + (ref_word != hypothesis[j - 1])
            up = previous[j] + 1
            left = current[j - 1] + 1
            best = min(diagonal, up, left)
            current[j] = best
            directions[i * width + j] = 0 if best == diagonal else (1 if best == up else 2)
        previous = current
    deleted = [False] * n
    i, j = n, m
    while i > 0 or j > 0:
        move = directions[i * width + j]
        if move == 0:
            i -= 1
            j -= 1
        elif move == 1:
            deleted[i - 1] = True
            i -= 1
        else:
            j -= 1
    return previous[-1], deleted


def wer(reference, hypothesis):
    """Word error rate: word-level edit distance over the reference length."""
    distance, _ = align(reference, hypothesis)
    return distance / max(len(reference), 1)


def dropped_reference_words(deleted):
    """Sum of the lengths of every run of 25 or more consecutive deletions.

    A run under 25 is ordinary far-field word error — scattered substitutions
    and short gaps `wer` already prices. Only a long, unbroken stretch with no
    hypothesis word at all is the failure mode this metric exists to catch: a
    whole decoded window silently missing.
    """
    total = run = 0
    for word_was_deleted in deleted:
        if word_was_deleted:
            run += 1
        else:
            if run >= 25:
                total += run
            run = 0
    if run >= 25:
        total += run
    return total


def dropped_stats(deleted, reference_length):
    """The long-deletion-run word count from `align`, and its share of the reference.

    Isolated from `meeting()` so the wiring between `align`'s deletions and the
    two reported fields can be tested directly, against a synthetic `deleted`
    array, without a database, cache root, or manifest.
    """
    dropped = dropped_reference_words(deleted)
    fraction = dropped / reference_length if reference_length else 0.0
    return dropped, fraction


def note_items(note):
    """Each bullet under Action Items and Decisions, as its text and its quote.

    FrontmatterRenderer writes a bullet as one `- <text>` line followed by one
    `  > ` line per line of the quote, so the text is whatever follows `- `.
    """
    sections = {"Action Items": [], "Decisions": []}
    current = bullet = None
    for line in note.split("\n"):
        if line.startswith("## "):
            current = line[3:] if line[3:] in sections else None
            bullet = None
        elif current and line.startswith("- "):
            bullet = {"text": line[2:].strip(), "quote": []}
            sections[current].append(bullet)
        elif current and bullet is not None and line.startswith("  >"):
            bullet["quote"].append(line[3:].strip())
    for items in sections.values():
        for item in items:
            item["quote"] = "\n".join(item["quote"])
    return sections


def overlap(expected, kept):
    """Share of the shorter side's words that the longer one also holds.

    The model often quotes only the start of the passage a reference item
    covers, so overlap is measured against the shorter side. A kept string
    under four words never counts: it would match almost anything.
    """
    want = words(expected)
    have = words(kept)
    if len(have) < MIN_QUOTE_WORDS or not want:
        return 0.0
    shorter, longer = (want, have) if len(want) <= len(have) else (have, want)
    pool = list(longer)
    hit = 0
    for word in shorter:
        if word in pool:
            pool.remove(word)
            hit += 1
    return hit / len(shorter)


def matches(expected, kept, item_text_overlap):
    """Whether a kept note item carries an expected item, by either of two tests.

    A quote test alone scores zero for a correct item the model supported with
    a different sentence of the same discussion, which is a judgement about the
    curator's sentence choice rather than about whether the item survived. The
    second test compares the two item descriptions instead. Either is
    sufficient. `text` is optional on the exit run's expected files, and an
    absent one scores zero, leaving the quote test to decide alone.
    """
    return (
        overlap(expected["quote"], kept["quote"]) >= RECALL_OVERLAP
        or overlap(expected.get("text", ""), kept["text"]) >= item_text_overlap
    )


SECTIONS = {"Action Items": "action_items", "Decisions": "decisions"}


def score_note(note, hypothesis, expected, item_text_overlap):
    """Scores one note's Action Items and Decisions against the reference.

    The one place a note is turned into numbers. `meeting` reaches it with a
    WhisperKit transcript as `hypothesis`; the offline bench reaches it with
    the reference transcript the note was summarized from. Both get the same
    two tests over the same note, so the bench and this suite cannot report
    different recall for the same output.

    Every count is reported per section as well as in total, because the two
    sections fail in opposite directions and a total hides it: the summarizer
    under-produces action items and over-produces decisions, so a prompt that
    moves items from one section to the other holds the total flat while
    changing the thing being measured. The totals stay for the rows already
    committed to history.jsonl, which carry no per-section keys.
    """
    kept = note_items(note)
    wanted = {"Action Items": expected["action_items"], "Decisions": expected["decisions"]}
    result = {
        "kept_items": sum(len(v) for v in kept.values()),
        "ungrounded_quotes": sum(1 for v in kept.values() for i in v if i["quote"] not in hypothesis),
        "expected_items": sum(len(v) for v in wanted.values()),
        "recalled_items": 0,
        "false_keeps": 0,
    }
    for heading, suffix in SECTIONS.items():
        recalled = sum(1 for e in wanted[heading] if any(matches(e, k, item_text_overlap) for k in kept[heading]))
        false_keeps = sum(1 for k in kept[heading] if not any(matches(e, k, item_text_overlap) for e in wanted[heading]))
        result[f"kept_{suffix}"] = len(kept[heading])
        result[f"expected_{suffix}"] = len(wanted[heading])
        result[f"recalled_{suffix}"] = recalled
        result[f"false_keep_{suffix}"] = false_keeps
        result["recalled_items"] += recalled
        result["false_keeps"] += false_keeps
    return result


def thresholds_beside_this_script():
    """The calibration that belongs to the rule, read from beside the rule.

    `item_text_overlap` calibrates `matches`, so it travels with this script
    rather than with the `repo_root` a caller passes in. That argument supplies
    data — the manifest and the reference directories — and a caller scoring
    one checkout's meetings with another checkout's scorer must still get this
    checkout's threshold. Every path through `score_note` reads it here, so the
    bench and the regression suite cannot apply the same rule at two different
    thresholds.
    """
    return json.load(open(Path(__file__).parent / "thresholds.json", encoding="utf-8"))


def note(note_path, expected_path, transcript_path):
    hypothesis = json.load(open(transcript_path, encoding="utf-8"))["text"]
    expected = json.load(open(expected_path, encoding="utf-8"))
    item_text_overlap = thresholds_beside_this_script()["item_text_overlap"]
    print(json.dumps(score_note(open(note_path, encoding="utf-8").read(), hypothesis, expected, item_text_overlap)))


def scalar(db, sql, *args):
    row = db.execute(sql, args).fetchone()
    return row[0] if row else None


def meeting(meeting_id, ami_id, db_path, cache_root, repo_root):
    manifest = json.load(open(Path(repo_root) / "Tests/regression/ami/manifest.json"))
    item_text_overlap = thresholds_beside_this_script()["item_text_overlap"]
    entry = next(m for m in manifest["meetings"] if m["id"] == ami_id)
    reference_dir = Path(repo_root) / entry["reference"]
    cache = Path(cache_root) / meeting_id

    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    state, verified_at, note_path = db.execute(
        "SELECT state, COALESCE(verified_at, ''), COALESCE(vault_note_path, '') FROM meetings WHERE id = ?", (meeting_id,)
    ).fetchone()
    telemetry = db.execute(
        "SELECT COALESCE(grounding_method, ''), COALESCE(quote_validation_drop_count, 0), COALESCE(cost_usd, 0), "
        "COALESCE(diarization_review_cost_usd, 0), COALESCE(summarization_model, '') FROM telemetry WHERE meeting_id = ?",
        (meeting_id,),
    ).fetchone()
    grounding, drops, cost, review_cost, summarizer = telemetry
    transcribe_ms = scalar(db, "SELECT duration_ms FROM stage_events WHERE meeting_id = ? AND stage = 'transcribe' AND event = 'completed'", meeting_id)
    summarize_ms = scalar(db, "SELECT duration_ms FROM stage_events WHERE meeting_id = ? AND stage = 'summarize' AND event = 'completed'", meeting_id)
    transcribe_meta = json.loads(
        scalar(db, "SELECT metadata_json FROM stage_events WHERE meeting_id = ? AND stage = 'transcribe' AND event = 'completed'", meeting_id) or "{}"
    )

    result = {
        "ami_id": ami_id,
        "state": state,
        "verified_at_null": verified_at == "",
        "audio_seconds": entry["audio_seconds"],
        "transcribe_seconds": (transcribe_ms or 0) / 1000,
        "realtime_factor": ((transcribe_ms or 0) / 1000) / entry["audio_seconds"],
        "summarize_seconds": (summarize_ms or 0) / 1000,
        "transcription_model": transcribe_meta.get("model_id", ""),
        "diarization_model": transcribe_meta.get("diarize", {}).get("model_id", ""),
        "summarization_model": summarizer,
        "grounding_method": grounding,
        "drop_count": drops,
        "cost_usd": cost + review_cost,
    }

    hypothesis = json.load(open(cache / "transcript.json"))["text"]
    reference = json.load(open(reference_dir / "transcript.json"))["text"]
    reference_words = words(reference)
    distance, deleted = align(reference_words, words(hypothesis))
    result["wer"] = distance / max(len(reference_words), 1)
    dropped, fraction = dropped_stats(deleted, len(reference_words))
    result["dropped_reference_words"] = dropped
    result["dropped_reference_fraction"] = fraction

    diarization = json.load(open(cache / "diarization.json"))
    result["diarized_speakers"] = len({s["speaker_label"] for s in diarization["segments"]})
    result["expected_speakers"] = entry["attendees"]

    expected = json.load(open(reference_dir / "expected.json"))
    note_text = open(note_path, encoding="utf-8").read() if note_path else ""
    result.update(score_note(note_text, hypothesis, expected, item_text_overlap))
    print(json.dumps(result))


def require_the_rules_own_threshold(limits):
    """Refuses a thresholds file that redefines the rule the rows were scored by.

    The gates are per-invocation on purpose: `max_wer`, `max_realtime_factor`
    and `max_cost_usd` grade a run and have nothing to do with matching, so a
    caller may legitimately pass a stricter file. `item_text_overlap` is not
    one of them. It calibrates `matches`, the rows were already scored under
    the value beside this script, and re-declaring it here would print a number
    produced under one threshold beneath a heading claiming another. A file
    that omits the key is fine: it is only setting gates.
    """
    passed = limits.get("item_text_overlap")
    ours = thresholds_beside_this_script()["item_text_overlap"]
    if passed is not None and passed != ours:
        sys.exit(
            f"score.py report: this thresholds file sets item_text_overlap {passed}, "
            f"but the rows were scored at {ours}, the value beside score.py. "
            f"Re-score with this file's threshold, or drop the key and keep only the gates."
        )


def report(thresholds_path, results_path):
    limits = json.load(open(thresholds_path, encoding="utf-8"))
    require_the_rules_own_threshold(limits)
    rows = [json.loads(line) for line in open(results_path) if line.strip()]
    print(f"{'meeting':9} {'WER':>6} {'RTF':>6} {'spk':>5} {'kept':>5} {'drop':>5} {'refDrop':>7} {'recall':>7} {'false':>6} {'cost':>8}")
    breaches = []
    for r in rows:
        # A row written before false keeps, or before dropped-reference-words,
        # were measured prints `-`, never 0: a zero here would assert a count
        # nobody took, and would satisfy the corresponding limit on the
        # strength of it.
        false = f"{r['false_keeps']:6d}" if "false_keeps" in r else f"{'-':>6}"
        ref_drop = f"{r['dropped_reference_fraction']:7.1%}" if "dropped_reference_fraction" in r else f"{'-':>7}"
        print(
            f"{r['ami_id']:9} {r['wer']:6.3f} {r['realtime_factor']:6.3f} "
            f"{r['diarized_speakers']}/{r['expected_speakers']:<3} {r['kept_items']:5d} {r['drop_count']:5d} "
            f"{ref_drop} {r['recalled_items']}/{r['expected_items']:<5} {false} ${r['cost_usd']:7.4f}"
        )
        name = r["ami_id"]
        checks = [
            (r["state"] == "awaiting_verification", "state is not awaiting_verification"),
            (r["verified_at_null"], "verified_at is set"),
            (r["ungrounded_quotes"] == 0, "a note quote is not in the transcript"),
            (r["wer"] <= limits["max_wer"], f"wer {r['wer']:.3f} > {limits['max_wer']}"),
            (r["realtime_factor"] <= limits["max_realtime_factor"], f"realtime factor {r['realtime_factor']:.3f} > {limits['max_realtime_factor']}"),
            (r["cost_usd"] <= limits["max_cost_usd"], f"cost ${r['cost_usd']:.4f} > ${limits['max_cost_usd']}"),
        ]
        if "dropped_reference_fraction" in r and "max_dropped_reference_fraction" not in limits:
            sys.exit(
                "score.py report: this thresholds file has no max_dropped_reference_fraction, "
                "but the rows carry dropped_reference_fraction. Add the limit, or drop the key from every row."
            )
        if "dropped_reference_fraction" in r:
            checks.append((
                r["dropped_reference_fraction"] <= limits["max_dropped_reference_fraction"],
                f"dropped reference fraction {r['dropped_reference_fraction']:.1%} > {limits['max_dropped_reference_fraction']:.0%}",
            ))
        breaches += [f"{name}: {why}" for ok, why in checks if not ok]
    # The summarization call sets no `temperature` (`claude-opus-5` accepts
    # none), so item recall is not reproducible between full-pipeline runs of
    # the same code: three runs of one fixed prompt and transcript set have
    # scored 10, 10 and 14 of 19. A gate calibrated on one such draw is a gate
    # calibrated on noise, so the three set-level aggregates (item recall,
    # false keeps, dropped reference fraction) gate on the median of the three
    # newest complete runs sharing the newest revision, never on a single run.
    # A run is complete when it covers every AMI id this file has ever scored;
    # a raw results file (`run.sh`'s own per-invocation check, with no
    # `run_at`/`revision` on any row) is always exactly one run of everything
    # it holds.
    all_ami_ids = {r["ami_id"] for r in rows}
    by_run = {}
    for r in rows:
        by_run.setdefault((r.get("run_at"), r.get("revision")), []).append(r)
    complete_runs = [(key, group) for key, group in by_run.items() if {r["ami_id"] for r in group} == all_ami_ids]

    def run_recall(group):
        expected = sum(r["expected_items"] for r in group)
        recalled = sum(r["recalled_items"] for r in group)
        return recalled / expected if expected else 1.0

    def run_false_keeps(group):
        return sum(r["false_keeps"] for r in group) if all("false_keeps" in r for r in group) else None

    def run_dropped_fraction(group):
        fractions = [r["dropped_reference_fraction"] for r in group if "dropped_reference_fraction" in r]
        return sum(fractions) / len(fractions) if fractions else None

    if not complete_runs:
        print("item recall: no run in this file covers every AMI id it has ever scored")
    else:
        newest_revision = max(complete_runs, key=lambda item: item[0][0] or "")[0][1]
        runs_at_revision = sorted(
            (group for key, group in complete_runs if key[1] == newest_revision),
            key=lambda group: group[0].get("run_at") or "",
            reverse=True,
        )
        selected = runs_at_revision[:3]
        recalls = [run_recall(g) for g in selected]
        median_recall = statistics.median(recalls)
        per_run = ", ".join(f"{r:.0%}" for r in recalls)
        print(f"item recall, revision {newest_revision}: median {median_recall:.0%} of {len(selected)} run(s) ({per_run})")
        if len(selected) < 3:
            print(f"  not yet gated: needs 3 complete runs at this revision, has {len(selected)}")
        else:
            if median_recall < limits["min_item_recall"]:
                breaches.append(f"item recall median {median_recall:.0%} < {limits['min_item_recall']:.0%}")

            false_keep_values = [v for v in (run_false_keeps(g) for g in selected) if v is not None]
            if len(false_keep_values) < len(selected):
                print("false keeps not measured on every one of the 3 selected runs")
            else:
                median_false_keeps = statistics.median(false_keep_values)
                print(f"false keeps: median {median_false_keeps:g} of 3 runs ({false_keep_values})")
                if median_false_keeps > limits["max_false_keeps"]:
                    breaches.append(f"false keeps median {median_false_keeps:g} > {limits['max_false_keeps']}")

            dropped_values = [v for v in (run_dropped_fraction(g) for g in selected) if v is not None]
            if len(dropped_values) < len(selected):
                print("dropped reference fraction not measured on every one of the 3 selected runs")
            else:
                median_dropped = statistics.median(dropped_values)
                print(f"dropped reference fraction: median {median_dropped:.1%} of 3 runs")
                if median_dropped > limits["max_dropped_reference_fraction"]:
                    breaches.append(f"dropped reference fraction median {median_dropped:.1%} > {limits['max_dropped_reference_fraction']:.0%}")

        older = len(complete_runs) - len(selected)
        if older:
            print(f"  {older} older complete run(s) printed above for context only, not gated")

    for breach in breaches:
        print(f"REGRESSION: {breach}", file=sys.stderr)
    sys.exit(1 if breaches else 0)


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"meeting": meeting, "note": note, "report": report}[command](*args)
