#!/bin/sh
# Regression check for .swiftlint.yml's custom_rules: each is a hand-written
# regex with no compiler to catch a typo that silently stops it matching, and
# `swiftlint lint` against the real tree exits 0 identically whether a rule
# works or is dead, since nothing in the tree matches any of the patterns
# outside their own exclusions.
#
# This lints scripts/lint-fixtures/CustomLintRuleFixtures.swift — which
# deliberately violates every rule — and asserts that each line marked
# `// expect: <rule id>` produced a violation of that rule on that line.
#
# Line-level, not per-rule: most of these regexes are chains of alternatives
# (`write(to:)` vs `write(toFile:)` vs `createFile`), and a check that only
# asked whether a rule id appeared somewhere in the output would pass while
# every alternative but one had gone blind. That is not hypothetical — the
# toFile: spelling went unmatched under exactly that weaker check.
#
# Runs the same way locally and in CI: ./scripts/verify-custom-lint-rules.sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$repo_root/scripts/lint-fixtures/CustomLintRuleFixtures.swift"
config="$repo_root/.swiftlint.yml"

# Kept out of the repo root: anything written there would surface in the
# `git status` cleanliness gate ci.yml runs after `tuist generate`.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

# No --force-exclude: that flag makes swiftlint *honor* .swiftlint.yml's
# excluded list even for an explicitly-named path, which would skip this
# fixture entirely (it's deliberately in that list so the normal repo-wide
# pass ignores it). Passing the path directly, without that flag, is what
# lints it anyway.
mise exec -- swiftlint lint --no-cache --config "$config" "$fixture" > "$work/output" 2>&1 || true
cat "$work/output"

# The rule id must close the line, so this file's own prose description of
# the marker syntax is not itself collected as a marker.
grep -n '// expect: ' "$fixture" \
    | sed -nE 's|^([0-9]+):.*// expect: ([a-z_]+)[[:space:]]*$|\1 \2|p' > "$work/expected"
if [ ! -s "$work/expected" ]; then
    echo "::error::Fixture self-check: no '// expect:' markers found in $fixture — the check would pass vacuously."
    exit 1
fi

failed=0
while read -r line rule; do
    if ! grep -q "CustomLintRuleFixtures\.swift:$line:[0-9]*: error:.*($rule)" "$work/output"; then
        echo "::error file=scripts/lint-fixtures/CustomLintRuleFixtures.swift,line=$line::Fixture self-check: rule '$rule' did not fire on line $line, which is marked as a known violation of it — that branch of the rule may be dead."
        failed=1
    fi
done < "$work/expected"

# Every rule must still be represented, so deleting a fixture's only marked
# line cannot quietly retire the rule along with it.
sed -n '/^custom_rules:/,$p' "$config" | sed -nE 's|^  ([a-z_]+):$|\1|p' > "$work/rules"
while read -r rule; do
    if ! grep -q " $rule$" "$work/expected"; then
        echo "::error::Fixture self-check: custom rule '$rule' has no '// expect: $rule' line in the fixture — it is unverified."
        failed=1
    fi
done < "$work/rules"

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "Fixture self-check: $(wc -l < "$work/expected" | tr -d ' ') marked lines each fired their expected rule."
