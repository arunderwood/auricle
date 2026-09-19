#!/usr/bin/env bash
# Decision 3.6 strategy comparison (Story 3.8 calls it the smoke test): builds
# auricle-cli and runs the Citations and substring summarizers over real
# transcripts. This SPENDS ANTHROPIC API CREDIT (one call per transcript per
# arm) and is run by hand, never in CI.
#
#   AURICLE_COMPARISON_TRANSCRIPTS   directory of CanonicalTranscript fixtures, as
#                                    <name>.json files or <name>/transcript.json
#                                    subdirectories (default:
#                                    Tests/fixtures/strategy-comparison-transcripts).
#                                    The committed eval fixtures are one such
#                                    directory: Tests/SummarizeTests/Fixtures/eval
#
# Each run writes results.md and detail.md into its own UTC-timestamped
# directory under Tests/fixtures/strategy-comparison-output/, so a re-run never
# overwrites human-scored cells filled into an earlier run. Both that
# directory and the default transcripts directory are gitignored.
#
# results.md holds no item text and no quotes, but fixture file names appear
# in it as given: name fixtures neutrally before copying it into
# Tests/fixtures/smoke-test-results.md, the path Story 3.8 fixes. detail.md is
# real meeting content and is never committed.
#
# An empty transcripts directory makes the verb refuse before any API call,
# so this script exits non-zero having spent nothing.
set -euo pipefail

invocation_dir=$PWD
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

transcripts=${AURICLE_COMPARISON_TRANSCRIPTS:-Tests/fixtures/strategy-comparison-transcripts}
# Not created here: the verb creates it after it has found transcripts, so an
# empty transcripts directory leaves nothing behind.
output=Tests/fixtures/strategy-comparison-output/$(date -u +%Y%m%dT%H%M%SZ)

# A quoted "~" reaches this script unexpanded.
case $transcripts in
    "~") transcripts=$HOME ;;
    "~/"*) transcripts=$HOME/${transcripts#"~/"} ;;
esac

# An override is relative to where the caller ran this from, the default to
# the repo root; the verb sees only absolute paths either way.
case $transcripts in
    /*) ;;
    *)
        if [ -n "${AURICLE_COMPARISON_TRANSCRIPTS:-}" ]; then
            transcripts=$invocation_dir/$transcripts
        else
            transcripts=$repo_root/$transcripts
        fi
        ;;
esac
output=$repo_root/$output

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
if [ -z "$built_products_dir" ] || [ ! -x "$built_products_dir/auricle-cli" ]; then
    echo "run-strategy-comparison: could not locate the built auricle-cli (looked in '${built_products_dir:-<unset>}')" >&2
    exit 1
fi

echo "==> auricle-cli __compare-strategies" >&2
exec "$built_products_dir/auricle-cli" __compare-strategies --transcripts "$transcripts" --output "$output"
