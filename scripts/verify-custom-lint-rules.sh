#!/bin/sh
# Regression check for .swiftlint.yml's 6 custom_rules: each is a
# hand-written regex with no compiler to catch a typo that silently stops
# it matching, and `swiftlint lint` against the real tree exits 0
# identically whether a rule works or is dead, since nothing in the tree
# matches any of the six patterns outside their own exclusions. This lints
# scripts/lint-fixtures/CustomLintRuleFixtures.swift — which deliberately
# violates every one of them — and fails if any expected rule id doesn't
# show up in the output.
#
# Runs the same way locally and in CI: ./scripts/verify-custom-lint-rules.sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$repo_root/scripts/lint-fixtures/CustomLintRuleFixtures.swift"

# No --force-exclude: that flag makes swiftlint *honor* .swiftlint.yml's
# excluded list even for an explicitly-named path, which would skip this
# fixture entirely (it's deliberately in that list so the normal repo-wide
# pass ignores it). Passing the path directly, without that flag, is what
# lints it anyway.
output=$(mise exec -- swiftlint lint --no-cache --config "$repo_root/.swiftlint.yml" "$fixture" 2>&1 || true)
echo "$output"

missing=0
for rule in atomic_writer_bypass log_facade_bypass transcript_decode_bypass telemetry_sql_bypass composition_root_strategy_bypass accessibility_label_missing; do
  if ! echo "$output" | grep -q "($rule)"; then
    echo "::error::Fixture self-check: custom rule '$rule' did not fire against its known-violating fixture — the rule may be dead."
    missing=1
  fi
done

exit "$missing"
