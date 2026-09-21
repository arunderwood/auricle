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
# <ID>.expected.json holding the attendee count from the manifest and the
# action items and decisions from the meeting's reference expected.json. The
# expected file omits "speakers", so the exit run uses --publish-anyway: AMI
# speaker names are not scored here, only the count.
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

python3 - "$here/manifest.json" "$repo_root" "$cache" "$fixtures" <<'PY' >&2
import json
import pathlib
import sys

manifest_path, repo_root, cache, fixtures = (pathlib.Path(p) for p in sys.argv[1:5])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

for meeting in manifest["meetings"]:
    ami = meeting["id"]
    audio = cache / f"{ami}.Mix-Headset.wav"
    if not audio.is_file():
        sys.exit(f"prepare-exit-fixtures: {ami}: no audio at {audio}.")
    (fixtures / f"{ami}.wav").symlink_to(audio)

    reference = json.loads((repo_root / meeting["reference"] / "expected.json").read_text(encoding="utf-8"))
    items = [
        {"section": section, "quote": item["quote"]}
        for section in ("action_items", "decisions")
        for item in reference.get(section, [])
    ]
    expected = {"attendees": meeting["attendees"], "items": items}
    (fixtures / f"{ami}.expected.json").write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{ami}: {len(items)} expected items", file=sys.stderr)
PY

echo "$fixtures"
