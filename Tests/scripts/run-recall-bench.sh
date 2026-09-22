#!/usr/bin/env bash
# Story 4.11's offline recall bench: builds auricle-cli and summarizes the five
# frozen AMI reference transcripts named by Tests/regression/ami/manifest.json,
# then scores each rendered note with `score.py note`. This SPENDS ANTHROPIC API
# CREDIT (one call per transcript per arm) and is run by hand, never in CI.
#
# With no --arm the verb runs the default PAIR of arms (citations and
# substring), so a bare run is ten paid calls, not five. The story's "under
# $0.30 and under two minutes" figure is per arm: pass a single --arm to get a
# five-call run.
#
# No audio, no WhisperKit, no state database and no vault: the transcripts are
# the committed reference ones, so a run measures the summarization prompt and
# nothing upstream of it.
#
#   AURICLE_CLI   path to an already-built auricle-cli, to skip the build.
#
# Each run writes its notes and report.txt into its own UTC-timestamped
# directory under Tests/fixtures/recall-bench-output/, which is gitignored, so
# a re-run never overwrites an earlier arm's numbers. The notes hold real
# meeting content from a public corpus; the report holds only the numbers.
#
# Extra arguments go to the verb. `--arm substring --arm substring:<dir>`
# compares two prompt sets over the same transcripts; <dir> holds the prompt
# files to override (system.md, substring.md), and any file it lacks falls back
# to the bundled one. `--diarized` joins diarization.json and attribution.json
# beside each fixture's transcript.json, so utterances carry real per-speaker
# labels instead of one placeholder; a fixture missing either file falls back
# to its transcript as written. --repo-root can point at a "shadow root" that
# only holds Tests/regression/ami/{manifest.json,score.py,thresholds.json} and
# reference/<id>/ fixtures, not a full checkout, which is how a WhisperKit
# transcript set (not the committed human reference) gets benched.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

output=$repo_root/Tests/fixtures/recall-bench-output/$(date -u +%Y%m%dT%H%M%SZ)

cli=${AURICLE_CLI:-}
if [ -z "$cli" ]; then
    workspace=App/Auricle.xcworkspace

    # auricle-cli is a Tuist-generated Xcode target, so SwiftPM cannot build it.
    echo "==> tuist generate" >&2
    (cd App && mise exec -- tuist generate --no-open) >&2

    echo "==> xcodebuild auricle-cli" >&2
    xcodebuild -workspace "$workspace" -scheme auricle-cli -destination "platform=macOS" build >&2

    built_products_dir=$(
        xcodebuild -workspace "$workspace" -scheme auricle-cli -destination "platform=macOS" -showBuildSettings 2>/dev/null \
            | awk '$1 == "BUILT_PRODUCTS_DIR" && $2 == "=" { print $3; exit }'
    )
    cli=$built_products_dir/auricle-cli
fi

if [ ! -x "$cli" ]; then
    echo "run-recall-bench: no executable auricle-cli at '${cli:-<unset>}'" >&2
    exit 1
fi

mkdir -p "$output"

# The report's own first lines say what produced it: an arm label reduces a
# prompt directory to its last path component, so /a/v2 and /b/v2 are
# indistinguishable in the table, and the timestamped directory records only
# when the run happened.
{
    echo "# invocation: $cli __recall-bench --repo-root $repo_root --output $output $*"
    echo "# output: $output"
    echo
} > "$output/report.txt"

echo "==> auricle-cli __recall-bench" >&2
"$cli" __recall-bench --repo-root "$repo_root" --output "$output" "$@" | tee -a "$output/report.txt"
