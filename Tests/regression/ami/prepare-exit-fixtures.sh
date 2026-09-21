#!/usr/bin/env bash
# Builds a fixture directory for Tests/scripts/run-epic4-exit-criteria.sh out of
# the AMI meetings in manifest.json, and prints its path on standard output.
#
#   AURICLE_EXIT_FIXTURES=$(Tests/regression/ami/prepare-exit-fixtures.sh) \
#       Tests/scripts/run-epic4-exit-criteria.sh
#
#   AURICLE_AMI_CACHE   audio cache (default: ~/Library/Caches/auricle-ami)
#
# Each meeting gets a symlink <ID>.wav to the cached audio and an
# <ID>.expected.json holding the attendee count from the manifest and one item
# per action item and decision in the meeting's reference expected.json. The
# expected file omits "speakers", so the exit run uses --publish-anyway: AMI
# speaker names are not scored here, only the count.
#
# Each item's quote is the match fragment from exit-fragments.json, not the
# reference quote. The exit script matches by exact substring against the
# pipeline's own transcription of the audio, and the reference quotes are a
# separate human transcript of the same speech, so a long reference quote never
# matches. Every reference item needs a fragment; a missing one fails here
# rather than silently scoring zero.
#
# The directory is temporary and holds no audio of its own. Nothing it writes
# belongs in the repository.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../../.." && pwd)
cache=${AURICLE_AMI_CACHE:-$HOME/Library/Caches/auricle-ami}

command -v python3 >/dev/null || { echo "prepare-exit-fixtures: python3 is required." >&2; exit 1; }

"$here/fetch.sh"

fixtures=$(mktemp -d "${TMPDIR:-/tmp}/auricle-ami-exit.XXXXXX")

python3 - "$here/manifest.json" "$here/exit-fragments.json" "$repo_root" "$cache" "$fixtures" <<'PY' >&2 || { rm -rf "$fixtures"; exit 1; }
import json
import pathlib
import sys

manifest_path, fragments_path, repo_root, cache, fixtures = (pathlib.Path(p) for p in sys.argv[1:6])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
fragments = json.loads(fragments_path.read_text(encoding="utf-8"))["meetings"]

for meeting in manifest["meetings"]:
    ami = meeting["id"]
    audio = cache / f"{ami}.Mix-Headset.wav"
    if not audio.is_file():
        sys.exit(f"prepare-exit-fixtures: {ami}: no audio at {audio}.")
    (fixtures / f"{ami}.wav").symlink_to(audio)

    by_quote = {entry["quote"]: entry["fragment"] for entry in fragments.get(ami, [])}
    reference = json.loads((repo_root / meeting["reference"] / "expected.json").read_text(encoding="utf-8"))

    items = []
    for section in ("action_items", "decisions"):
        for item in reference.get(section, []):
            quote = item["quote"]
            fragment = by_quote.get(quote)
            if fragment is None:
                sys.exit(f"prepare-exit-fixtures: {ami}: exit-fragments.json has no fragment for {quote[:50]!r}.")
            if fragment not in quote:
                sys.exit(f"prepare-exit-fixtures: {ami}: fragment {fragment!r} is not a substring of its quote.")
            items.append({"section": section, "quote": fragment})

    expected = {"attendees": meeting["attendees"], "items": items}
    (fixtures / f"{ami}.expected.json").write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{ami}: {len(items)} expected items", file=sys.stderr)
PY

echo "$fixtures"
