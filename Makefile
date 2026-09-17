.PHONY: check check-lint check-swift check-release check-app build build-release test lint format format-check xcodebuild

# Mirrors ci.yml's full gate chain — run before pushing. See scripts/check.sh.
check:
	scripts/check.sh

# The individual phases, each the same command one CI job runs.
check-lint:
	scripts/check.sh lint

check-swift:
	scripts/check.sh swift

check-release:
	scripts/check.sh release

check-app:
	scripts/check.sh app

build:
	swift build --explicit-target-dependency-import-check error

build-release:
	swift build -c release

test:
	swift test --explicit-target-dependency-import-check error

lint:
	mise exec -- swiftlint lint --strict .
	scripts/verify-custom-lint-rules.sh

format:
	mise exec -- swiftformat .

format-check:
	mise exec -- swiftformat --lint .

xcodebuild:
	cd App && mise exec -- tuist generate --no-open
	xcodebuild -workspace App/Auricle.xcworkspace -scheme AuricleApp -destination "platform=macOS" build
	xcodebuild -workspace App/Auricle.xcworkspace -scheme auricle-cli -destination "platform=macOS" build
