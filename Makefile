.PHONY: check build build-release test lint format format-check xcodebuild

# Mirrors ci.yml's full gate chain — run before pushing. See scripts/check.sh.
check:
	scripts/check.sh

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
	xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp -destination "platform=macOS" build
	xcodebuild -project App/Auricle.xcodeproj -scheme auricle-cli -destination "platform=macOS" build
