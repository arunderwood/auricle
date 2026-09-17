#!/bin/sh
# The full build/lint/test gate, in the same order and with the same flags
# ci.yml runs — a single command to mirror CI locally before pushing.
# `make check` and ci.yml's main step both call this; there is exactly one
# copy of this sequence; the other is not more, and does not risk drifting
# out of sync with it.
#
# Deliberately excludes ci.yml's two git-hygiene checks (tracked generated
# project, dirty tree after `tuist generate`): those assert the working
# tree is clean, which is true of a fresh CI checkout but never true of a
# real local working tree mid-change — running them here would false-positive
# on a developer's own in-progress edits, not on anything this script did.
#
# Runs the same way locally and in CI: ./scripts/check.sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

echo "==> mise install"
mise install

echo "==> swiftformat --lint"
mise exec -- swiftformat --lint .

echo "==> swiftlint"
mise exec -- swiftlint lint --strict .

echo "==> verify-custom-lint-rules (fixture self-check)"
scripts/verify-custom-lint-rules.sh

# AR-INIT-2 (Package.swift:1-6): plain `swift build` does not reject an
# undeclared cross-target import — this flag is what makes the module
# boundary build-enforced. `swift test` compiles test targets through its
# own separate build, so it needs the same flag to close the same gap for
# test-target imports.
echo "==> swift build (explicit target dependency import check)"
swift build --explicit-target-dependency-import-check error

# deferred-work.md:41-43: automates the exact release build already
# manually run and accepted as sufficient during Story 1.3's review.
echo "==> swift build -c release"
swift build -c release

echo "==> swift test"
swift test --explicit-target-dependency-import-check error

echo "==> tuist generate"
(cd App && mise exec -- tuist generate --no-open)

echo "==> xcodebuild AuricleApp"
xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp -destination "platform=macOS" build

echo "==> xcodebuild auricle-cli"
xcodebuild -project App/Auricle.xcodeproj -scheme auricle-cli -destination "platform=macOS" build

echo "==> all checks passed"
