#!/usr/bin/env bash
# Epic 4 exit-criteria live run (Story 4.10 Part B). It uses the real WhisperKit
# models and SPENDS ANTHROPIC API CREDIT, on the maintainer's private
# recordings. It is run by hand, never in CI. Part A, the CI pipeline test, is
# Tests/IntegrationTests/PipelineEndToEndTests.swift.
#
#   AURICLE_EXIT_FIXTURES   directory of recordings, required. Each recording
#                           <name>.<audio extension> has a sibling
#                           <name>.expected.json:
#                             {
#                               "attendees": 4,
#                               "speakers": "1=Ben,2=Sara",
#                               "items": [
#                                 {"section": "action_items", "quote": "<verbatim transcript text>"},
#                                 {"section": "decisions",    "quote": "<verbatim transcript text>"}
#                               ]
#                             }
#                           "speakers" is optional; without it the run uses
#                           --publish-anyway. An expected item survives when its
#                           quote appears in a note block quote under that
#                           section's heading. The AMI meeting audio (CC BY 4.0)
#                           behind the Epic 3 fixtures is an allowed public source.
#
# Needs: the app launched once (it creates the database), `vault_path` set in
# ~/.auricle/config.toml, and an Anthropic API key in the Keychain. The cost
# ceiling follows the config: $0.50 with [diarization_review] enabled = false
# (or absent), $0.60 with it true. Run once per setting.
#
# Standard output holds opaque labels (fixture-1 ...) and numbers only: no
# transcript text, no quote text and no titles. Paste it into
# Tests/fixtures/epic4-exit-results.md. Never commit the recordings or the
# expected files.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

fail() {
    echo "run-epic4-exit-criteria: $*" >&2
    exit 1
}

fixtures=${AURICLE_EXIT_FIXTURES:-}
[ -n "$fixtures" ] || fail "AURICLE_EXIT_FIXTURES is not set."
case $fixtures in
    "~") fixtures=$HOME ;;
    "~/"*) fixtures=$HOME/${fixtures#"~/"} ;;
esac
[ -d "$fixtures" ] || fail "AURICLE_EXIT_FIXTURES is not a directory."
command -v python3 >/dev/null || fail "python3 is required."
command -v sqlite3 >/dev/null || fail "sqlite3 is required."

recordings=()
while IFS= read -r expected; do
    base=${expected%.expected.json}
    audio=
    for candidate in "$base".*; do
        case $candidate in
            *.expected.json) ;;
            *) audio=$candidate ;;
        esac
    done
    [ -n "$audio" ] || fail "an expected file has no recording next to it."
    recordings+=("$audio")
done < <(find "$fixtures" -maxdepth 1 -name '*.expected.json' | sort)

[ "${#recordings[@]}" -ge 5 ] || fail "need at least 5 recordings; found ${#recordings[@]}."

# Set-shape check before anything is built or spent.
python3 - "$fixtures" <<'PY' || exit 1
import glob, json, sys
attendees = [json.load(open(p))["attendees"] for p in glob.glob(sys.argv[1] + "/*.expected.json")]
if sum(1 for a in attendees if a >= 4) < 2:
    sys.exit("run-epic4-exit-criteria: the set needs at least two recordings with 4 or more attendees.")
PY

config=$HOME/.auricle/config.toml
review=false
if [ -f "$config" ] && awk '/^\[/ { in_section = ($0 == "[diarization_review]") } in_section && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true/ { found = 1 } END { exit !found }' "$config"; then
    review=true
fi
if [ "$review" = true ]; then ceiling=0.60; else ceiling=0.50; fi

database=$HOME/Library/Application\ Support/com.auricle.app/auricle.sqlite3
[ -f "$database" ] || fail "no state database. Launch the app once so it creates it."
cache_root=$HOME/Library/Caches/com.auricle.app

workspace=App/Auricle.xcworkspace
echo "==> tuist generate" >&2
(cd App && mise exec -- tuist generate --no-open) >&2
echo "==> xcodebuild auricle-cli" >&2
xcodebuild -workspace "$workspace" -scheme auricle-cli -destination "platform=macOS" build >&2
built_products_dir=$(
    xcodebuild -workspace "$workspace" -scheme auricle-cli -destination "platform=macOS" -showBuildSettings 2>/dev/null \
        | awk '$1 == "BUILT_PRODUCTS_DIR" && $2 == "=" { print $3; exit }'
)
cli=$built_products_dir/auricle-cli
[ -x "$cli" ] || fail "could not locate the built auricle-cli."

results=$(mktemp)
trap 'rm -f "$results"' EXIT

index=0
for audio in "${recordings[@]}"; do
    index=$((index + 1))
    label=fixture-$index
    expected=${audio%.*}.expected.json

    meeting_id=$("$cli" __internal-import "$audio") || fail "$label: import failed."

    speakers=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("speakers",""))' "$expected")
    if [ -n "$speakers" ]; then
        "$cli" run "$meeting_id" --to review-diarization >/dev/null || fail "$label: run exited non-zero before attribution."
        "$cli" attribute "$meeting_id" --speakers "$speakers" >/dev/null || fail "$label: attribute failed."
        "$cli" run "$meeting_id" >/dev/null || fail "$label: run exited non-zero."
    else
        "$cli" run "$meeting_id" --publish-anyway >/dev/null || fail "$label: run exited non-zero."
    fi

    # `auricle status <id>` is a stub until Story 9.6, so read the row directly.
    note_path=$(sqlite3 "$database" "SELECT COALESCE(vault_note_path, '') FROM meetings WHERE id = '$meeting_id';")
    verified_at=$(sqlite3 "$database" "SELECT COALESCE(verified_at, '') FROM meetings WHERE id = '$meeting_id';")
    [ -z "$verified_at" ] || fail "$label: meetings.verified_at is set."
    [ -n "$note_path" ] && [ -f "$note_path" ] || fail "$label: no vault note at meetings.vault_note_path."

    telemetry=$(sqlite3 -separator ' ' "$database" \
        "SELECT COALESCE(grounding_method, ''), COALESCE(quote_validation_drop_count, 0), COALESCE(cost_usd, 0) + COALESCE(diarization_review_cost_usd, 0) FROM telemetry WHERE meeting_id = '$meeting_id';")
    [ -n "$telemetry" ] || fail "$label: no telemetry row."

    # Prints "<kept> <expected> <survived>" or exits non-zero with a label-only message.
    counts=$(python3 - "$label" "$note_path" "$cache_root/$meeting_id/transcript.json" "$expected" <<'PY'
import json, re, sys

label, note_path, transcript_path, expected_path = sys.argv[1:5]
note = open(note_path, encoding="utf-8").read()
transcript = json.load(open(transcript_path, encoding="utf-8"))["text"]

fence = re.match(r"\A﻿?---[ \t]*\n(.*?)\n---[ \t]*\n", note, re.S)
if not fence or "auricle:" not in fence.group(1) or "schema_version:" not in fence.group(1) or "meeting_id:" not in fence.group(1):
    sys.exit(f"run-epic4-exit-criteria: {label}: frontmatter is not schema-valid.")
if not re.search(r"(^|/)\d{4}-\d{2}-\d{2}-[^/]+\.md$", note_path):
    sys.exit(f"run-epic4-exit-criteria: {label}: note is not at a FilenameResolver-shaped path.")

sections = {"Action Items": [], "Decisions": []}
current = None
bullet = None
for line in note.split("\n"):
    if line.startswith("## "):
        current = line[3:] if line[3:] in sections else None
        bullet = None
    elif current and line.startswith("- "):
        bullet = []
        sections[current].append(bullet)
    elif current and bullet is not None and line.startswith("  >"):
        bullet.append(line[3:].strip())

def squash(text):
    return " ".join(text.split())

kept = 0
quotes = {"action_items": [], "decisions": []}
for heading, key in (("Action Items", "action_items"), ("Decisions", "decisions")):
    for bullet in sections[heading]:
        if not bullet:
            sys.exit(f"run-epic4-exit-criteria: {label}: an item has no source quote.")
        quote = "\n".join(bullet)
        if quote not in transcript:
            sys.exit(f"run-epic4-exit-criteria: {label}: a quote does not match the transcript.")
        quotes[key].append(squash(quote))
        kept += 1

expected = json.load(open(expected_path, encoding="utf-8"))["items"]
survived = sum(1 for item in expected if any(squash(item["quote"]) in q for q in quotes[item["section"]]))
print(kept, len(expected), survived)
PY
    ) || exit 1

    read -r grounding drops cost <<<"$telemetry"
    read -r kept expected_count survived <<<"$counts"
    echo "$label $grounding $kept $expected_count $survived $drops $cost" >>"$results"
    printf 'fixture-%s: vault note written · grounding_method=%s · kept %s items (%s expected) · drop count %s · cost $%.4f\n' \
        "$index" "$grounding" "$kept" "$expected_count" "$drops" "$cost"
done

python3 - "$results" "$ceiling" "$review" <<'PY' || exit 1
import sys

rows = [line.split() for line in open(sys.argv[1]) if line.strip()]
ceiling, review = float(sys.argv[2]), sys.argv[3]
expected = sum(int(r[3]) for r in rows)
survived = sum(int(r[4]) for r in rows)
total_cost = sum(float(r[6]) for r in rows)
rate = 100.0 * survived / expected if expected else 0.0

worst = max(float(r[6]) for r in rows)
if worst > ceiling:
    sys.exit(f"Epic 4 exit criteria not met: per-meeting cost = ${worst:.4f} (ceiling ${ceiling:.2f}, diarization_review.enabled = {review})")
if rate < 80.0:
    sys.exit(f"Epic 4 exit criteria not met: pass rate = {rate:.1f}%")
print(f"Epic 4 exit criteria met: pass rate {rate:.1f}%, total cost ${total_cost:.2f} over {len(rows)} fixtures")
PY
