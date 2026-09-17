"""Shared probe document and encoding helpers for the citation-offset investigation.

Both probes index into the same document so their results are directly comparable: if the
session probe surfaces citations, its offsets can be read against the direct-API probe's
established unit without re-deriving anything.

Stdlib only, so the session probe needs no Anthropic SDK to import this.
"""

from __future__ import annotations

import json
import subprocess
import unicodedata

# The prefix carries three things whose encodings diverge:
#
#   char          UTF-8 bytes   UTF-16 units   codepoints   graphemes
#   "a"                1             1             1            1
#   "e" (U+00E9)       2             1             1            1     precomposed
#   "=" (U+1F600)      4             2             1            1     non-BMP
#   "e" + U+0301       3             2             2            1     decomposed
#   "a" + U+0329       3             2             2            1     no precomposed form
#
# U+0329 (combining vertical line below) on a plain "a" has no precomposed form, so it
# survives NFC untouched while still costing 2 codepoints for 1 grapheme. Without it,
# codepoints and graphemes are equal in any NFC string and those two hypotheses cannot be
# told apart.

#: Already NFC. Isolates the encoding unit with no normalization confound.
PREFIX_NFC = (
    "Field log \U0001F600\U0001F600\U0001F600 from café naïve résumé "
    "a̩a̩a̩ station. "
)

#: Identical, except the composable accents are decomposed. If the server NFC-normalizes
#: before indexing, this prefix's offsets collapse onto PREFIX_NFC's.
PREFIX_NFD = (
    "Field log \U0001F600\U0001F600\U0001F600 from café naïve résumé "
    "a̩a̩a̩ station. "
)

#: Holds the nonce. Unguessable without the document, so its presence in an answer proves
#: the document's content actually reached the model.
TARGET = "The Auricle beacon transmits at exactly 1427 hertz."
NONCE = "1427"

TAIL = " Maintenance occurs on the first Tuesday of each month."

QUESTION = (
    "At what frequency does the Auricle beacon transmit? "
    "Answer in one short sentence and cite the document."
)

UNITS = ("utf8_bytes", "utf16_units", "codepoints", "graphemes")


def document(prefix: str = PREFIX_NFC) -> str:
    """The full probe document for a given prefix."""
    return prefix + TARGET + TAIL


def counts(s: str) -> dict[str, int]:
    """The four candidate lengths of ``s``, one per hypothesis."""
    return {
        "utf8_bytes": len(s.encode("utf-8")),
        "utf16_units": len(s.encode("utf-16-le")) // 2,
        "codepoints": len(s),
        "graphemes": _grapheme_count(s),
    }


def _grapheme_count(s: str) -> int:
    # The stdlib has no grapheme segmentation. For these controlled strings, a codepoint
    # count less its combining marks is exact.
    return sum(1 for ch in s if unicodedata.combining(ch) == 0)


def _clusters(s: str) -> list[str]:
    clusters: list[str] = []
    buf = ""
    for ch in s:
        if unicodedata.combining(ch) and buf:
            buf += ch
        else:
            if buf:
                clusters.append(buf)
            buf = ch
    if buf:
        clusters.append(buf)
    return clusters


def slice_as(doc: str, start: int, end: int, unit: str) -> str | None:
    """Slice ``doc`` at ``[start:end)`` interpreting the offsets as ``unit``.

    Returns None when the offsets do not describe a valid slice under that unit, which is
    itself evidence against the hypothesis.
    """
    try:
        if unit == "codepoints":
            return doc[start:end]
        if unit == "utf8_bytes":
            return doc.encode("utf-8")[start:end].decode("utf-8")
        if unit == "utf16_units":
            return doc.encode("utf-16-le")[start * 2 : end * 2].decode("utf-16-le")
        if unit == "graphemes":
            return "".join(_clusters(doc)[start:end])
    except (UnicodeDecodeError, IndexError):
        return None
    return None


def matching_units(doc: str, start: int, end: int, cited_text: str) -> list[str]:
    """Which encodings' slice of ``doc`` reproduces ``cited_text`` exactly.

    This is the decisive test and it self-validates: arithmetic can coincide, but a slice
    that reproduces the server's own quoted text cannot be a coincidence.
    """
    return [u for u in UNITS if slice_as(doc, start, end, u) == cited_text]


# --------------------------------------------------------------------------- session driver
#
# Shared by every session-level probe. Kept here so the experiments differ only in the message
# they send and the assertion they make, never in how the session is driven.


def user_message(content: list[dict]) -> str:
    """One stream-json input line carrying a user message with arbitrary content blocks."""
    return json.dumps(
        {"type": "user", "message": {"role": "user", "content": content}, "parent_tool_use_id": None}
    )


def run_claude_session(
    content: list[dict],
    *,
    cwd: str,
    extra_args: list[str] | None = None,
    timeout: int = 240,
    partial_messages: bool = True,
    max_turns: int = 1,
) -> dict:
    """Drive one ``claude -p`` session over stream-json and return every emitted message.

    ``partial_messages`` defaults to True because citation payloads arrive only as
    ``citations_delta`` stream events; without it they are invisible (see [P1]/[P4]).
    """
    cmd = [
        "claude", "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--max-turns", str(max_turns),
    ]
    if partial_messages:
        cmd.append("--include-partial-messages")
    cmd += extra_args or []

    try:
        proc = subprocess.run(
            cmd, input=user_message(content) + "\n",
            capture_output=True, text=True, timeout=timeout, cwd=cwd,
        )
    except subprocess.TimeoutExpired:
        return {"timeout": True, "messages": [], "stderr": "", "exit_code": None, "cmd": cmd}

    messages = []
    for line in proc.stdout.splitlines():
        if line := line.strip():
            try:
                messages.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    return {
        "timeout": False,
        "exit_code": proc.returncode,
        "stderr": proc.stderr[:4000],
        "messages": messages,
        "cmd": cmd,
    }


def citations_from_stream(messages: list[dict]) -> list[dict]:
    """Every citation object carried by a ``citations_delta`` stream event.

    This is the only surface that carries them; the reassembled assistant message shows an
    empty array. See [P1] and [P4] in research.md.
    """
    out = []
    for m in messages:
        if m.get("type") != "stream_event":
            continue
        delta = m.get("event", {}).get("delta", {})
        if delta.get("type") == "citations_delta" and (c := delta.get("citation")):
            out.append(c)
    return out


def result_message(messages: list[dict]) -> dict | None:
    for m in messages:
        if m.get("type") == "result":
            return m
    return None


def assistant_text(messages: list[dict]) -> str:
    parts = []
    for m in messages:
        if m.get("type") != "assistant":
            continue
        for b in m.get("message", {}).get("content") or []:
            if b.get("type") == "text":
                parts.append(b.get("text", ""))
    return "".join(parts)


def session_error(messages: list[dict]) -> str | None:
    """A human-readable error if the session failed, else None."""
    res = result_message(messages)
    if res is None:
        return "no result message"
    if res.get("is_error") or res.get("subtype") not in (None, "success"):
        return f"subtype={res.get('subtype')} result={str(res.get('result'))[:300]}"
    return None
