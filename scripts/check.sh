#!/bin/sh
# The build/lint/test gate, in the same order and with the same flags ci.yml
# runs. `make check` and ci.yml both call this; there is exactly one copy of
# the sequence, so the local gate and the CI gate cannot drift apart.
#
# The phases exist because CI runs them as three independent jobs in parallel.
# With no argument every phase runs in order, which is what a developer wants
# before pushing.
#
#   scripts/check.sh            every phase, in order
#   scripts/check.sh lint       formatting, linting, workflow linting, and the
#                               two fixture self-checks
#   scripts/check.sh swift      SwiftPM debug build + tests
#   scripts/check.sh release    SwiftPM release build + Log.debug strip check
#   scripts/check.sh app        tuist generate + both Xcode schemes + the
#                               embedded-worker assertion
#
# Deliberately excludes ci.yml's two git-hygiene checks (tracked generated
# project, dirty tree after `tuist generate`): those assert the working tree
# is clean, which is true of a fresh CI checkout but never true of a real
# local working tree mid-change — running them here would false-positive on a
# developer's own in-progress edits, not on anything this script did.
#
# Runs the same way locally and in CI: ./scripts/check.sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

phase_lint() {
    echo "==> swiftformat --lint"
    mise exec -- swiftformat --lint .

    echo "==> swiftlint"
    mise exec -- swiftlint lint --strict .

    echo "==> verify-custom-lint-rules (fixture self-check)"
    scripts/verify-custom-lint-rules.sh

    # The AMI scorer decides the Epic 4 number and carries a calibrated
    # threshold, but it is Python, so `swift test` never reaches it.
    echo "==> ami scorer self-check"
    python3 Tests/regression/ami/test_score.py

    # history.jsonl is the only committed corpus of real result rows, and a
    # scorer change breaks it more easily than anything synthetic: its rows
    # were written by older scorers and need not carry today's fields. This
    # asserts that the formatter and the thresholds survive real data. It is
    # not a quality assertion — the rows mix revisions.
    echo "==> ami report over the recorded history"
    python3 Tests/regression/ami/score.py report Tests/regression/ami/thresholds.json Tests/regression/ami/history.jsonl

    echo "==> actionlint"
    mise exec -- actionlint -color

    # Every action is required to be pinned to a full commit SHA; a tag is
    # mutable and the workflow runs with a token that can read the repo.
    echo "==> zizmor"
    mise exec -- zizmor --persona=regular --no-progress .github/
}

phase_swift() {
    # AR-INIT-2 (Package.swift:1-6): plain `swift build` does not reject an
    # undeclared cross-target import — this flag is what makes the module
    # boundary build-enforced. `swift test` compiles test targets through its
    # own separate build, so it needs the same flag to close the same gap for
    # test-target imports.
    echo "==> swift build (explicit target dependency import check)"
    swift build --explicit-target-dependency-import-check error

    echo "==> swift test"
    swift test --explicit-target-dependency-import-check error
}

phase_release() {
    echo "==> swift build -c release"
    swift build -c release

    # A successful release build does not show that `Log.debug` is stripped:
    # the code compiles the same with its `#if DEBUG` guard deleted. The
    # tests run in debug, so only this step sees the release machine code.
    echo "==> verify Log.debug is stripped from the release build"
    scripts/verify-release-debug-log-stripped.sh
}

# The value of one build setting for the AuricleApp target, read from the
# `$build_settings` text `phase_app` captures. Filtering by target name keeps
# this right if the scheme ever builds more than one target.
app_build_setting() {
    printf '%s\n' "$build_settings" | awk -v key="$1" '
        /^Build settings for action build and target / { in_app = ($NF == "AuricleApp:") }
        in_app && $1 == key && $2 == "=" { sub(/^[^=]*= /, ""); print; exit }'
}

phase_app() {
    echo "==> tuist generate"
    (cd App && mise exec -- tuist generate --no-open)

    # Build the workspace tuist generates, not the .xcodeproj inside it.
    # `tuist generate` resolves the package graph into the workspace's derived
    # data; xcodebuild against the bare project computes a different derived
    # data path and re-resolves every package from scratch.
    build_settings=$(xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp -destination "platform=macOS" -showBuildSettings)
    target_build_dir=$(app_build_setting TARGET_BUILD_DIR)
    product_name=$(app_build_setting FULL_PRODUCT_NAME)
    executable_folder=$(app_build_setting EXECUTABLE_FOLDER_PATH)
    case "$product_name" in
        *.app) ;;
        *)
            echo "error: could not read AuricleApp's product name from xcodebuild -showBuildSettings." >&2
            exit 1
            ;;
    esac
    if [ -z "$target_build_dir" ] || [ -z "$executable_folder" ]; then
        echo "error: could not read AuricleApp's build directory from xcodebuild -showBuildSettings." >&2
        exit 1
    fi

    # An incremental build reuses the bundle on disk, and removing the embed
    # step from Project.swift does not delete a binary an earlier build
    # already copied in. Building from no bundle makes the assertion below
    # describe this build, not the last one.
    rm -rf "${target_build_dir:?}/$product_name"

    echo "==> xcodebuild AuricleApp"
    xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp -destination "platform=macOS" build

    echo "==> xcodebuild auricle-cli"
    xcodebuild -workspace App/Auricle.xcworkspace -scheme auricle-cli -destination "platform=macOS" build

    # Nothing else proves the worker is embedded: `swift test` never reaches
    # App/, and both builds succeed without the copy step. The dispatcher
    # resolves the worker with Bundle.main.url(forAuxiliaryExecutable:), which
    # looks in the bundle's executable folder, so that folder is where the
    # binary has to be.
    echo "==> auricle-cli embedded in $product_name"
    embedded_cli="$target_build_dir/$executable_folder/auricle-cli"
    if [ ! -f "$embedded_cli" ] || [ ! -x "$embedded_cli" ]; then
        echo "error: $embedded_cli is missing or not executable." >&2
        echo "SubprocessDispatcher finds the worker with Bundle.main.url(forAuxiliaryExecutable: \"auricle-cli\"), so every subprocess dispatch from the app would fail." >&2
        echo "Check the copyFiles and productName settings in App/Project.swift." >&2
        exit 1
    fi
}

echo "==> mise install"
mise install

case "${1:-all}" in
    lint) phase_lint ;;
    swift) phase_swift ;;
    release) phase_release ;;
    app) phase_app ;;
    all)
        phase_lint
        phase_swift
        phase_release
        phase_app
        ;;
    *)
        echo "usage: $0 [lint|swift|release|app]" >&2
        exit 2
        ;;
esac

echo "==> checks passed: ${1:-all}"
