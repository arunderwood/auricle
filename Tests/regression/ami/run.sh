#!/usr/bin/env bash
# AMI regression, performance and model-tracking run. It uses the real
# WhisperKit and diarization models and SPENDS ANTHROPIC API CREDIT (about a
# dollar for all four meetings). Run it by hand, never in CI.
#
#   run.sh [AMI-ID ...]     meetings to run (default: all in manifest.json)
#
#   AURICLE_AMI_CACHE       audio cache (default: ~/Library/Caches/auricle-ami)
#   AURICLE_CLI             path to a built auricle-cli; skips the build
#   AURICLE_AMI_RECORD=1    append this run's numbers to history.jsonl
#
# Needs the same setup as Tests/scripts/run-epic4-exit-criteria.sh: the app
# launched once, `vault_path` in ~/.auricle/config.toml (use a scratch vault:
# every run publishes a note), and an Anthropic key in the Keychain.
#
# Each meeting is imported fresh and run with --publish-anyway. Diarization
# labels are not scored for speaker attribution, only counted: the transcriber
# labels every utterance Speaker_1 until the speaker-join fix lands.
#
# Output holds numbers only. history.jsonl is committed, so it never gets
# transcript text, quotes or titles. Models are recorded, not selected: the
# transcriber, diarizer and summarizer models are the ones the CLI ships with,
# and changing one is a code change that shows up as a history row.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../../.." && pwd)
cd "$repo_root"

fail() {
    echo "ami-regression: $*" >&2
    exit 1
}

command -v python3 >/dev/null || fail "python3 is required."
command -v sqlite3 >/dev/null || fail "sqlite3 is required."
database=$HOME/Library/Application\ Support/com.auricle.app/auricle.sqlite3
[ -f "$database" ] || fail "no state database. Launch the app once so it creates it."
cache_root=$HOME/Library/Caches/com.auricle.app
audio_cache=${AURICLE_AMI_CACHE:-$HOME/Library/Caches/auricle-ami}

"$here/fetch.sh"

cli=${AURICLE_CLI:-}
if [ -z "$cli" ]; then
    echo "==> build auricle-cli" >&2
    (cd App && mise exec -- tuist generate --no-open) >&2
    workspace=App/Auricle.xcworkspace
    xcodebuild -workspace "$workspace" -scheme auricle-cli -destination "platform=macOS" build >&2
    products=$(
        xcodebuild -workspace "$workspace" -scheme auricle-cli -destination "platform=macOS" -showBuildSettings 2>/dev/null \
            | awk '$1 == "BUILT_PRODUCTS_DIR" && $2 == "=" { print $3; exit }'
    )
    cli=$products/auricle-cli
fi
[ -x "$cli" ] || fail "could not locate auricle-cli."

if [ "$#" -gt 0 ]; then
    meetings=("$@")
else
    meetings=()
    while IFS= read -r ami; do meetings+=("$ami"); done < <(python3 -c 'import json; print("\n".join(m["id"] for m in json.load(open("Tests/regression/ami/manifest.json"))["meetings"]))')
fi

results=$(mktemp)
trap 'rm -f "$results"' EXIT

for ami in "${meetings[@]}"; do
    echo "==> $ami" >&2
    id=$("$cli" __internal-import "$audio_cache/$ami.Mix-Headset.wav") || fail "$ami: import failed."
    "$cli" run "$id" --publish-anyway >/dev/null || fail "$ami: run exited non-zero."
    python3 "$here/score.py" meeting "$id" "$ami" "$database" "$cache_root" "$repo_root" >>"$results" || fail "$ami: scoring failed."
done

if [ "${AURICLE_AMI_RECORD:-}" = 1 ]; then
    python3 - "$results" "$here/history.jsonl" "$(git rev-parse HEAD)" <<'PY'
import datetime, json, sys
results, history, revision = sys.argv[1:4]
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(history, "a") as out:
    for line in open(results):
        if line.strip():
            out.write(json.dumps({"run_at": stamp, "revision": revision, **json.loads(line)}) + "\n")
PY
fi

python3 "$here/score.py" report "$here/thresholds.json" "$results"
