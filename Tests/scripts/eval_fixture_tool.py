#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "typer>=0.12",
#   "loguru>=0.7",
# ]
# ///
"""Builds the summarize-stage eval fixtures under Tests/SummarizeTests/Fixtures/eval/.

Both converters follow Decision 3.4: speakers become Speaker_N in order of first
appearance, each utterance reads `Speaker_N: text`, utterances are joined by LF,
the text is NFC, and every offset is a UTF-8 byte offset with an exclusive end
that includes the utterance's label. They print the speaker map to stdout as JSON
so a fixture's expected.json can record who each label is.

Exit codes: 0 success, 1 bad input (unreadable file, malformed line, quote not
found or ambiguous), 2 CLI misuse (typer).
"""

from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path

import typer
from loguru import logger

app = typer.Typer(add_completion=False, no_args_is_help=True)

AMI_TAG = re.compile(r"\{[^}]*\}")
SPACE_BEFORE_PUNCT = re.compile(r"\s+([,.?!;:])")
WHITESPACE_RUNS = re.compile(r"\s+")


def fail(message: str, *args: object) -> typer.Exit:
    logger.error(message, *args)
    return typer.Exit(1)


def write_json(path: Path, value: object) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.rename(path)


def build_transcript(lines: list[str]) -> tuple[dict, dict[str, str]]:
    labels: dict[str, str] = {}
    utterances: list[dict] = []
    parts: list[str] = []
    cursor = 0
    for raw in lines:
        if not raw.strip():
            continue
        name, _, said = raw.partition(": ")
        if not said.strip():
            raise fail("line is not 'NAME: text': {!r}", raw[:40])
        label = labels.setdefault(name, f"Speaker_{len(labels) + 1}")
        body = unicodedata.normalize("NFC", f"{label}: {said.strip()}")
        size = len(body.encode("utf-8"))
        utterances.append({"speaker_label": label, "start": cursor, "end": cursor + size})
        parts.append(body)
        cursor += size + 1  # the LF separator
    doc = {"text": "\n".join(parts), "utterances": utterances}
    verify(doc)
    return doc, labels


def verify(doc: dict) -> None:
    data = doc["text"].encode("utf-8")
    if not unicodedata.is_normalized("NFC", doc["text"]) or "\r" in doc["text"]:
        raise fail("text is not NFC with LF line endings")
    for utterance in doc["utterances"]:
        piece = data[utterance["start"] : utterance["end"]].decode("utf-8")
        if not piece.startswith(utterance["speaker_label"] + ": "):
            raise fail("range does not start at its label: {!r}", piece[:30])


def clean_ami(text: str) -> str:
    text = AMI_TAG.sub(" ", text)
    text = SPACE_BEFORE_PUNCT.sub(r"\1", text)
    return WHITESPACE_RUNS.sub(" ", text).strip()


@app.command()
def dialogue(
    source: Path = typer.Argument(..., exists=True, dir_okay=False, help="Cleaned `NAME: text` lines, one utterance each."),
    output: Path = typer.Argument(..., help="transcript.json to write."),
) -> None:
    """Convert cleaned `NAME: text` lines to a CanonicalTranscript."""
    doc, labels = build_transcript(source.read_text(encoding="utf-8").splitlines())
    write_json(output, doc)
    logger.success("{} utterances, {} speakers -> {}", len(doc["utterances"]), len(labels), output)
    print(json.dumps(labels, indent=2))


@app.command()
def qmsum(
    source: Path = typer.Argument(..., exists=True, dir_okay=False, help="A QMSum meeting file (AMI-derived)."),
    output: Path = typer.Argument(..., help="transcript.json to write."),
) -> None:
    """Convert a QMSum meeting to a CanonicalTranscript, stripping AMI markup tags."""
    meeting = json.loads(source.read_text(encoding="utf-8"))
    lines = []
    for utterance in meeting["meeting_transcripts"]:
        said = clean_ami(utterance["content"])
        if re.search(r"\w", said):
            lines.append(f"{utterance['speaker']}: {said}")
    doc, labels = build_transcript(lines)
    write_json(output, doc)
    logger.success("{} utterances, {} speakers -> {}", len(doc["utterances"]), len(labels), output)
    print(json.dumps(labels, indent=2))


@app.command()
def resolve(
    transcript: Path = typer.Argument(..., exists=True, dir_okay=False, help="transcript.json"),
    expected: Path = typer.Argument(..., exists=True, dir_okay=False, help="expected.json to fill in place."),
) -> None:
    """Fill transcript_start/transcript_end for each action item and decision from its verbatim quote."""
    text = json.loads(transcript.read_text(encoding="utf-8"))["text"].encode("utf-8")
    doc = json.loads(expected.read_text(encoding="utf-8"))
    for section in ("action_items", "decisions"):
        for item in doc.get(section, []):
            quote = item["quote"].encode("utf-8")
            hits = [m.start() for m in re.finditer(re.escape(quote), text)]
            if not hits:
                raise fail("{}: quote not found verbatim: {!r}", section, item["quote"][:60])
            occurrence = item.get("occurrence")
            if occurrence is None and len(hits) > 1:
                raise fail("{}: quote occurs {} times, set 'occurrence': {!r}", section, len(hits), item["quote"][:60])
            start = hits[(occurrence or 1) - 1]
            item["transcript_start"] = start
            item["transcript_end"] = start + len(quote)
    write_json(expected, doc)
    logger.success("resolved {}", expected)


if __name__ == "__main__":
    app()
