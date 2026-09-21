#!/usr/bin/env python3
"""Scores one pipeline run against its AMI reference, and reports a run.

  score.py meeting <meeting-id> <ami-id> <db> <cache-root> <repo-root>
      Prints one JSON object of numbers. Reads the note, the cached transcript
      and diarization, and the state database. Prints no transcript text.
  score.py report <thresholds.json> <results.jsonl>
      Prints a table, checks the thresholds, exits 1 on a breach.
"""
import json
import re
import sqlite3
import sys
from pathlib import Path

FILLERS = {"um", "uh", "uhm", "mm", "hmm", "mhm", "mm-hmm", "erm", "ah", "er"}
RECALL_OVERLAP = 0.5
MIN_QUOTE_WORDS = 4


def words(text):
    text = re.sub(r"(?m)^Speaker_\d+:\s*", "", text).lower()
    text = re.sub(r"[^a-z0-9' -]", " ", text).replace("-", " ")
    return [w for w in text.split() if w not in FILLERS]


def wer(reference, hypothesis):
    """Word error rate: word-level edit distance over the reference length."""
    previous = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, 1):
        current = [i] + [0] * len(hypothesis)
        for j, hyp_word in enumerate(hypothesis, 1):
            current[j] = min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + (ref_word != hyp_word),
            )
        previous = current
    return previous[-1] / max(len(reference), 1)


def note_quotes(note):
    sections = {"Action Items": [], "Decisions": []}
    current = bullet = None
    for line in note.split("\n"):
        if line.startswith("## "):
            current = line[3:] if line[3:] in sections else None
            bullet = None
        elif current and line.startswith("- "):
            bullet = []
            sections[current].append(bullet)
        elif current and bullet is not None and line.startswith("  >"):
            bullet.append(line[3:].strip())
    return {name: ["\n".join(b) for b in bullets] for name, bullets in sections.items()}


def overlap(expected, kept):
    """Share of the shorter quote's words that the longer one also holds.

    The model often quotes only the start of the passage a reference item
    covers, so overlap is measured against the shorter side. A kept quote
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


def scalar(db, sql, *args):
    row = db.execute(sql, args).fetchone()
    return row[0] if row else None


def meeting(meeting_id, ami_id, db_path, cache_root, repo_root):
    manifest = json.load(open(Path(repo_root) / "Tests/regression/ami/manifest.json"))
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
    result["wer"] = wer(words(reference), words(hypothesis))

    diarization = json.load(open(cache / "diarization.json"))
    result["diarized_speakers"] = len({s["speaker_label"] for s in diarization["segments"]})
    result["expected_speakers"] = entry["attendees"]

    note = open(note_path, encoding="utf-8").read() if note_path else ""
    quotes = note_quotes(note)
    result["kept_items"] = sum(len(v) for v in quotes.values())
    result["ungrounded_quotes"] = sum(1 for v in quotes.values() for q in v if q not in hypothesis)

    expected = json.load(open(reference_dir / "expected.json"))
    wanted = [("Action Items", i["quote"]) for i in expected["action_items"]] + [("Decisions", i["quote"]) for i in expected["decisions"]]
    survived = sum(1 for heading, quote in wanted if any(overlap(quote, k) >= RECALL_OVERLAP for k in quotes[heading]))
    result["expected_items"] = len(wanted)
    result["recalled_items"] = survived
    print(json.dumps(result))


def report(thresholds_path, results_path):
    limits = json.load(open(thresholds_path))
    rows = [json.loads(line) for line in open(results_path) if line.strip()]
    print(f"{'meeting':9} {'WER':>6} {'RTF':>6} {'spk':>5} {'kept':>5} {'drop':>5} {'recall':>7} {'cost':>8}")
    breaches = []
    for r in rows:
        print(
            f"{r['ami_id']:9} {r['wer']:6.3f} {r['realtime_factor']:6.3f} "
            f"{r['diarized_speakers']}/{r['expected_speakers']:<3} {r['kept_items']:5d} {r['drop_count']:5d} "
            f"{r['recalled_items']}/{r['expected_items']:<5} ${r['cost_usd']:7.4f}"
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
        breaches += [f"{name}: {why}" for ok, why in checks if not ok]
    expected = sum(r["expected_items"] for r in rows)
    recalled = sum(r["recalled_items"] for r in rows)
    recall = recalled / expected if expected else 1.0
    print(f"item recall {recalled}/{expected} = {recall:.0%}")
    if recall < limits["min_item_recall"]:
        breaches.append(f"item recall {recall:.0%} < {limits['min_item_recall']:.0%}")
    for breach in breaches:
        print(f"REGRESSION: {breach}", file=sys.stderr)
    sys.exit(1 if breaches else 0)


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"meeting": meeting, "report": report}[command](*args)
