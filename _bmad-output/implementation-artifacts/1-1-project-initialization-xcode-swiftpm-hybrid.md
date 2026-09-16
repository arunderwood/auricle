# Story 1.1: Project Initialization (Xcode + SwiftPM Hybrid)

Status: done
Baseline Commit: 0a53390e241e44c6165578302b157b3ce7c24b1b

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the maintainer (in builder mode),
I want the auricle repository scaffolded with the hybrid SwiftPM library + Xcode app project structure declared in `Package.swift`,
So that every subsequent story can land in a target with explicit build-system-enforced module boundaries.

## Acceptance Criteria

### AC1 — `Package.swift` declares all 25 SwiftPM library targets + matching test targets + `TestSupport`

**Given** an empty repository directory (the repo root currently contains only `_bmad/` and `_bmad-output/` — no Swift code yet)
**When** I run `swift package init --type library --name AuricleKit` and then add the SwiftPM target list per AR-INIT-5
**Then** `Package.swift` declares all 25 SwiftPM library targets (`Core`, `State`, `Telemetry`, `Orchestrator`, `Permissions`, `Capture`, `TranscriberInterface`, `DiarizerInterface`, `SummarizerInterface`, `AIReviewerInterface`, `CalendarInterface`, `Transcribe`, `Diarize`, `Attribute`, `Summarize`, `ClaudeSummarizer`, `ClaudeAIReviewers`, `ReviewDiarization`, `WhisperKitTranscriber`, `WhisperKitDiarizer`, `GoogleCalendarSource`, `VaultGlossary`, `Persist`, `Verify`, `Notifications`) plus matching `<Target>Tests` test targets and `TestSupport`
**And** external SPM dependencies are declared (WhisperKit, GRDB.swift, swift-argument-parser, TOMLKit; Sparkle deferred for v1.1 with a `// Sparkle: v1.1, deferred — see AR-INIT-2` comment)
**And** `swift build` succeeds with no source files in any target (empty target compilation passes)
**And** `swift test` succeeds against every test target (empty test suites pass)

### AC2 — Xcode project at `App/Auricle.xcodeproj` produces both executables

**Given** Story 1.1 has set up `Package.swift`
**When** I declare two executable targets in `Project.swift` (`AuricleApp`, product `.app` + `auricle-cli`, product `.commandLineTool`) both depending on the root SwiftPM package, and run `tuist generate --no-open`
**Then** `App/Auricle.xcodeproj` is produced by the generator — it is never created or edited by hand, and never committed (AR-INIT-1, AR-PAT-11)
**And** `xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp build` succeeds for an empty `@main App { var body: some Scene { WindowGroup { Text("auricle") } } }` shell
**And** `xcodebuild -project App/Auricle.xcodeproj -scheme auricle-cli build` succeeds for an empty CLI binary (just enough swift-argument-parser scaffolding to compile — no verbs implemented; verbs land in Story 1.7)
**And** Hardened Runtime is ON, the App Sandbox key is absent entirely, deployment target is macOS 14, architecture is arm64-only — all declared in `config/Shared.xcconfig`, not in the Xcode UI
**And** deleting `App/Auricle.xcodeproj` and re-running `tuist generate` reproduces an equivalent project — the manifest is the only source of truth
**And** `Info.plist` carries `LSUIElement=NO`, `NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`, `NSUserNotificationsUsageDescription` strings in user voice per UX-DR44 (verbatim text in Dev Notes below)
**And** `Auricle.entitlements` includes `com.apple.security.device.audio-input` and notification entitlements; no `com.apple.security.app-sandbox`
**And** `CFBundleURLTypes` registers the `auricle://` URL scheme

### AC3 — Bundle identifier locked to `com.auricle.app`

**Given** the Xcode project builds
**When** I inspect `config/Shared.xcconfig` and the built product
**Then** `PRODUCT_BUNDLE_IDENTIFIER = com.auricle.app` (stable forever per NFR-S2 TCC permission persistence — never change this; TCC grants are keyed on bundle ID)
**And** `codesign -dv <built bundle>` reports that identifier, so the assertion is against the artifact rather than against a setting

### AC4 — Repository layout matches AR-INIT-5 + `.gitignore` correct

**Given** the project structure is in place
**When** I commit and push to the repository
**Then** the directory layout matches AR-INIT-5 exactly:
- `Sources/<Target>/` for every library target
- `Tests/<Target>Tests/` for every test target
- `App/Auricle.xcodeproj/`
- `App/Auricle/` (SwiftUI app shell sources)
- `App/auricle-cli/` (CLI executable sources)
- `scripts/` (empty placeholder; populated in Story 1.8 + Epic 9)
- `assets/` (empty placeholder; populated in Epic 9 with `auricle-root-ca.cer`)
- `_bmad-output/` (already exists — planning artifacts)

**And** `.gitignore` excludes `.build/`, `.swiftpm/`, `DerivedData/`, `xcuserdata/`, `App/Auricle.xcodeproj/`, `.tuist/`, `Derived/`
**And** `git ls-files --error-unmatch App/Auricle.xcodeproj` fails — the generated project is not tracked (AR-INIT-1, enforced in CI by Story 1.8)
**And** `Package.resolved` IS committed (listed in `.gitignore` as a comment for clarity, but tracked in git for reproducible builds per NFR-M7)

## Tasks / Subtasks

- [x] **Task 0: Tuist local-package spike** (gates every later task — do NOT start Task 1 until this passes)
  - [x] Install the toolchain: `mise install` if `mise.toml` exists, otherwise `brew install tuist` (Task 6 writes `mise.toml` properly)
  - [x] In a scratch directory OUTSIDE the repo, create a minimal `Package.swift` with one library target, and an `App/Project.swift` declaring one `.app` target with `packages: [.local(path: ".")]` and `dependencies: [.package(product: "TheLibrary")]`
  - [x] Run `tuist generate --no-open && xcodebuild -scheme <app> build` — must exit 0
  - [x] **If this fails:** stop. Fall back to XcodeGen (already installed, 2.46.0) with an identical `config/*.xcconfig` split — only the manifest language changes, because no build setting lives in the manifest. Record the failure and the deviation from AR-INIT-1 in the Dev Agent Record, and tell the user before proceeding.
  - [x] Delete the scratch directory. Do NOT commit it.

  **Why this gate exists:** the Tuist manifest API used by Tasks 6–8 is verified against Tuist's `ProjectDescription` sources (`Product.app`, `Product.commandLineTool`, `Package.local(path:)`, `TargetDependency.package(product:)`, `InfoPlist.file(path:)`, `Entitlements.file(path:)`, `Configuration.debug(name:settings:xcconfig:)` all exist as written). What is NOT verified is this specific arrangement — a project in `App/` consuming a SwiftPM package at the repository root. Thirty minutes here beats discovering it at Task 6.

- [x] **Task 1: Initialize SwiftPM package** (AC: #1)
  - [x] Run `swift package init --type library --name AuricleKit` at repo root (do NOT use `--type executable`; the manifest is the library; executables live in the Xcode project per AR-INIT-1)
  - [x] Delete the auto-generated `Sources/AuricleKit/AuricleKit.swift` and `Tests/AuricleKitTests/AuricleKitTests.swift` placeholder files — they belong to no real target
  - [x] Edit `Package.swift` per the manifest skeleton in **Dev Notes → Package.swift Skeleton** below
  - [x] Set `swift-tools-version: 5.10` on line 1 (required for Swift Testing per Architecture §Testing Framework)
  - [x] Set `platforms: [.macOS(.v14)]` (per AR-INIT-3 deployment target)
- [x] **Task 2: Declare all 26 library targets in `Package.swift`** (AC: #1)
  - [x] Declare 25 library targets per AR-INIT-5 in this order: cross-cutting first (`Core`, `State`, `Telemetry`, `Orchestrator`, `Permissions`), then capture (`Capture`), then interfaces (`TranscriberInterface`, `DiarizerInterface`, `SummarizerInterface`, `AIReviewerInterface`, `CalendarInterface`), then stages (`Transcribe`, `Diarize`, `Attribute`, `Summarize`, `Persist`, `Verify`, `Notifications`, `ReviewDiarization`), then concrete strategies (`ClaudeSummarizer`, `ClaudeAIReviewers`, `WhisperKitTranscriber`, `WhisperKitDiarizer`, `GoogleCalendarSource`, `VaultGlossary`)
  - [x] Declare the `TestSupport` library target (per AR-INIT-5 — test fixtures + composition root for tests, per Architecture §Test Organization)
  - [x] For each target, create the source directory `Sources/<Target>/` even if empty (SwiftPM requires the directory to exist; empty directories are not committed by git unless a `.gitkeep` is added — see Task 5)
  - [x] Wire dependency edges per **Dev Notes → Target Dependency Matrix** below — DO NOT add cross-edges that aren't listed (SwiftPM target boundaries are the architecture per AR-PAT-10 build-time enforcement)
  - [x] Each library target sets `path: "Sources/<TargetName>"` explicitly (not strictly required since names match defaults, but explicit-is-better keeps grep findable)
- [x] **Task 3: Declare 25 matching test targets in `Package.swift`** (AC: #1)
  - [x] Declare `<Target>Tests` for every library target (25 total) — per AR-INIT-5 + Architecture §Test Organization "One test target per source target"
  - [x] **EXCEPTION:** Interface-only targets (`TranscriberInterface`, `DiarizerInterface`, `SummarizerInterface`, `AIReviewerInterface`, `CalendarInterface`) may have `<Target>Tests` declared with a comment: `// Interface-only target — protocol declarations only; tests minimal/none. AR-PAT-1.` Still create the test target so the structure is uniform; later stories that ship the protocols add real tests.
  - [x] Each test target depends on its corresponding source target + `TestSupport`
  - [x] Each test target sets `path: "Tests/<TargetName>Tests"` explicitly
  - [x] Each test target uses Swift Testing (no need to import XCTest at the manifest level; the framework is implicit in Swift 5.10+)
- [x] **Task 4: Declare external SPM dependencies in `Package.swift`** (AC: #1)
  - [x] WhisperKit: `https://github.com/argmaxinc/WhisperKit.git` — `from: "0.9.0"` (use latest stable at scaffold time; pin via `Package.resolved`)
  - [x] GRDB.swift: `https://github.com/groue/GRDB.swift.git` — `from: "6.29.0"` (latest 6.x stable; do not jump to 7.x without architectural review of any breaking changes)
  - [x] swift-argument-parser: `https://github.com/apple/swift-argument-parser.git` — `from: "1.5.0"`
  - [x] TOMLKit: `https://github.com/LebJe/TOMLKit.git` — `from: "0.6.0"`
  - [x] Sparkle: declare as a top-of-file comment: `// MARK: - Deferred to v1.1 (AR-INIT-2) — Sparkle: https://github.com/sparkle-project/Sparkle.git from: "2.6.0"`
  - [x] Wire WhisperKit only into `WhisperKitTranscriber` and `WhisperKitDiarizer` targets
  - [x] Wire GRDB.swift only into `State` and `Telemetry` targets (per Architecture §SQLite Layer "Depended on by the State target only" — Telemetry is the second authorized SQL writer per AR-PAT-4)
  - [x] Wire swift-argument-parser into the `auricle-cli` Xcode target only (NOT into any SwiftPM library target; the CLI is the binding-contract surface per NFR-I7 and the parser is the executable-shell concern)
  - [x] Wire TOMLKit only into `Core` (config loader lives in `Core/Config.swift` per Story 1.2)
- [x] **Task 5: Create `Sources/<Target>/` and `Tests/<Target>Tests/` directories with `.gitkeep` placeholders** (AC: #1, #4)
  - [x] For each of the 25 library targets: `mkdir -p Sources/<Target>` and add `Sources/<Target>/.gitkeep` (zero-byte file — git tracks empty directories only via at-least-one tracked file)
  - [x] For `TestSupport`: `mkdir -p Sources/TestSupport` + `.gitkeep`
  - [x] For each of the 26 test targets: `mkdir -p Tests/<Target>Tests` + `.gitkeep`
  - [x] Verify `swift build` and `swift test` succeed against the empty package (this is AC1's "empty target compilation passes" gate — fail here means the manifest is wrong)
- [x] **Task 6: Write `mise.toml`, `Tuist.swift`, and `Project.swift`** (AC: #2, #3)
  - [x] `mise.toml` at repo root pinning exact versions of `tuist`, `swiftformat`, `swiftlint` (AR-INIT-6). Pin exact versions, not ranges — drift breaks NFR-M7's byte-identical-rebuild guarantee.
  - [x] `Tuist.swift` at repo root: `let tuist = Tuist(project: .tuist(generationOptions: .options()))`
  - [x] `Project.swift` at repo root: `packages: [.local(path: ".")]` — the root SwiftPM package
  - [x] Declare target `AuricleApp`: `destinations: [.mac]`, `product: .app`, `bundleId: "com.auricle.app"`, `deploymentTargets: .macOS("14.0")`, `infoPlist: .file(path: "App/Auricle/Info.plist")`, `entitlements: .file(path: "App/Auricle/Auricle.entitlements")`, `sources: ["App/Auricle/**"]`, and one `.package(product:)` dependency per library it consumes (see **Dev Notes → Composition Root Dependency List** below)
  - [x] Declare target `auricle-cli`: `destinations: [.mac]`, `product: .commandLineTool`, `sources: ["App/auricle-cli/**"]`, dependencies `.package(product:)` for swift-argument-parser plus every SwiftPM library product (CLI is the binding-contract surface; needs full library access per Architecture §Composition Roots)
  - [x] Project-level `settings:` → `.settings(configurations: [.debug(name: .debug, xcconfig: "config/Debug.xcconfig"), .release(name: .release, xcconfig: "config/Release.xcconfig")], defaultSettings: .none)`
  - [x] **`defaultSettings: .none` is load-bearing.** It stops Tuist injecting its own build settings, which would silently shadow the xcconfigs and make the plain-text files a lie.
  - [x] Run `tuist generate --no-open`; confirm `App/Auricle.xcodeproj` appears
  - [x] Confirm the generated project is ignored: `git status --porcelain` shows nothing under `App/` except the committed source directories
- [x] **Task 7: Write `config/*.xcconfig` and `App/Auricle/Info.plist`** (AC: #2, #3)
  - [x] `config/Shared.xcconfig`: `MACOSX_DEPLOYMENT_TARGET = 14.0`; `ARCHS = arm64`; `EXCLUDED_ARCHS = x86_64` (Apple Silicon only per Architecture §Technical Constraints "Apple Silicon only. M5 Max is reference hardware; M1 is the floor"); `ENABLE_HARDENED_RUNTIME = YES`; `PRODUCT_BUNDLE_IDENTIFIER = com.auricle.app`; `CODE_SIGN_ENTITLEMENTS = App/Auricle/Auricle.entitlements`; `SWIFT_VERSION = 5.10`
  - [x] **Do NOT add `ENABLE_APP_SANDBOX` in any form.** The key must be absent, not set to `NO` — the sandbox conflicts with ScreenCaptureKit and vault writes per Architecture §Technical Constraints.
  - [x] `config/Debug.xcconfig`: `#include "Shared.xcconfig"`; `CODE_SIGN_IDENTITY = -` (ad-hoc)
  - [x] `config/Release.xcconfig`: `#include "Shared.xcconfig"`; `CODE_SIGN_IDENTITY = Auricle Code Signing`; `CODE_SIGN_STYLE = Manual`. That identity does not exist until Story 9.3 creates it, so Release will not sign yet — expected, and Epic 9's problem rather than this story's.
  - [x] `App/Auricle/Info.plist` — hand-written XML, committed. Bundle identifier comes from `PRODUCT_BUNDLE_IDENTIFIER` via `$(PRODUCT_BUNDLE_IDENTIFIER)`; **DO NOT CHANGE** that value ever, per NFR-S2 (TCC permissions are keyed on bundle ID)
  - [x] Set `LSUIElement = NO` (auricle is a normal app with a Dock icon and main window per UX-DR1, not a menu bar accessory; menu-bar item arrives in v1.1 per FR8)
  - [x] Add `NSScreenCaptureUsageDescription` with verbatim string: `auricle records your meeting audio so it can transcribe what's said` (UX-DR44 — DO NOT paraphrase; user-voice copy is locked)
  - [x] Add `NSMicrophoneUsageDescription` with verbatim string: `auricle captures your voice alongside the meeting so your contributions are in the notes`
  - [x] Add `NSUserNotificationsUsageDescription` with verbatim string: `auricle pings you when a meeting is ready to review — usually just a click to confirm`
  - [x] Add `CFBundleURLTypes` array with one entry: `CFBundleURLName = "com.auricle.app.url"`, `CFBundleURLSchemes = ["auricle"]` (per AR-INIT-3 + Architecture §Notification / URL Scheme Names — registers `auricle://` for notification-click handlers per AR-FAIL-5)
  - [x] Verify both files parse: `plutil -lint App/Auricle/Info.plist`
- [x] **Task 8: Write `App/Auricle/Auricle.entitlements`** (AC: #2)
  - [x] Hand-written plist, committed at `App/Auricle/Auricle.entitlements`, containing `com.apple.security.device.audio-input` = `true`
  - [x] Verify the entitlements file does NOT contain `com.apple.security.app-sandbox` (would break ScreenCaptureKit + vault writes)
  - [x] `UNUserNotificationCenter` requires no entitlement key on macOS — authorization is requested at runtime and gated by `NSUserNotificationsUsageDescription`. Record that in a comment in `AuricleApp.swift` so the next reader does not go looking for a key that does not exist.
  - [x] Verify it parses: `plutil -lint App/Auricle/Auricle.entitlements`
- [x] **Task 9: Write minimal stub `@main` for AuricleApp + minimal swift-argument-parser scaffold for auricle-cli** (AC: #2)
  - [x] `App/Auricle/AuricleApp.swift`: declare `@main struct AuricleApp: App { var body: some Scene { WindowGroup { Text("auricle") } } }` — NOTHING ELSE. No `Orchestrator` instantiation, no view models, no concrete strategies. The composition root per AR-PAT-5 is implemented incrementally as later stories ship.
  - [x] `App/auricle-cli/main.swift`: declare `import ArgumentParser` + `@main struct AuricleCLI: AsyncParsableCommand { static let configuration = CommandConfiguration(commandName: "auricle", abstract: "Personal meeting notes pipeline") }` — NO subcommands yet. Story 1.7 ships the CLI scaffold with `status` + hidden `__internal-stage` per AR-PIPE-7.
- [x] **Task 10: Write `.gitignore`** (AC: #4)
  - [x] Add `.build/` (SwiftPM build output)
  - [x] Add `.swiftpm/` (SwiftPM local cache + xcode-generated package files)
  - [x] Add `DerivedData/` (Xcode build output)
  - [x] Add `App/Auricle.xcodeproj/` — the generated Xcode project. Never committed; regenerate with `tuist generate` (AR-INIT-1). CI fails the build if it is tracked (Story 1.8).
  - [x] Add `.tuist/` and `Derived/` (Tuist local cache and derived artifacts)
  - [x] Add `xcuserdata/` (Xcode per-user state — `*.xcodeproj/xcuserdata/` and `*.xcworkspace/xcuserdata/`)
  - [x] **DO NOT** add `Package.resolved` to `.gitignore` — it's committed for reproducible builds (NFR-M7). Add a comment in `.gitignore`: `# Package.resolved IS committed (reproducible builds per NFR-M7)`
  - [x] Add `.DS_Store` (cosmetic; macOS junk)
  - [x] Add `*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is NOT excluded — Xcode's auto-managed lockfile mirror is fine to commit alongside the SwiftPM root `Package.resolved`
- [x] **Task 11: Verify the complete build chain works end-to-end** (AC: #1, #2, #4)
  - [x] From repo root: `swift build` → must exit 0
  - [x] From repo root: `swift test` → must exit 0 (no tests run, but no compile errors)
  - [x] From repo root: `tuist generate --no-open` → must exit 0
  - [x] From repo root: `xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp -destination 'platform=macOS,arch=arm64' build` → must exit 0
  - [x] From repo root: `xcodebuild -project App/Auricle.xcodeproj -scheme auricle-cli -destination 'platform=macOS,arch=arm64' build` → must exit 0
  - [x] Prove the project is reproducible from the manifest alone: `rm -rf App/Auricle.xcodeproj && tuist generate --no-open && xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp -destination 'platform=macOS,arch=arm64' build` → must exit 0. This is the whole point of AR-INIT-1; if it fails, the project is carrying state that lives nowhere in version control.
  - [x] Confirm the generated project is untracked: `git ls-files --error-unmatch App/Auricle.xcodeproj` → must FAIL (non-zero exit)
  - [x] Spot-check one cross-target import that should fail: in `Sources/Capture/.gitkeep` add a temporary `Sources/Capture/_TestImport.swift` containing `import Transcribe`; run `swift build`; confirm SwiftPM rejects the build with a "no such module" error (per AR-INIT-1 + AR-PAT-10 build-time enforcement); then DELETE the test file. **DO NOT COMMIT this verification artifact** — its existence is what we're proving the manifest *forbids*.

## Dev Notes

### Why Story 1.1 is the foundational gate

This is the very first story in the project; the repository today contains only `_bmad/` (BMad config) and `_bmad-output/` (planning artifacts). Every subsequent story in every epic depends on `Package.swift` declaring the correct target boundaries, because **SwiftPM target boundaries ARE the architecture** (Architecture §Module Boundaries: "Mechanical SOLID enforcement"). A target that's missing here forces a manifest revision later, which is a small but real friction; a target that's wrong here (e.g., `Capture` accidentally depending on `Transcribe`) lets stage code reach across the boundary and silently breaks SRP enforcement.

The acceptance criteria are unusually mechanical (file paths, target names, verbatim Info.plist strings) **on purpose**: this story is pure scaffolding. The judgment calls were already made — by the architect, in the AR-INIT-1 through AR-INIT-5 commitments and the §Repository Layout / §Composition Roots sections of `architecture.md`.

### What's IN scope vs. OUT of scope (DO NOT exceed scope)

**IN scope (this story):**
- `Package.swift` with all 26 library targets + 26 test targets + external dependency declarations
- `mise.toml`, `Tuist.swift`, `Project.swift`, and `config/*.xcconfig` — the declarative Xcode half
- `Info.plist`, `Auricle.entitlements`, `.gitignore`
- Empty source directories with `.gitkeep` placeholders so git tracks them
- Minimal stub `@main` for AuricleApp (Text("auricle") in a WindowGroup) + minimal `auricle` CLI scaffold (no subcommands)

**OUT of scope (later stories — DO NOT implement here):**
- Any actual code in `Sources/<Target>/*.swift` beyond `.gitkeep` placeholders — Stories 1.2 through 1.7 fill these in. **Resist the temptation** to add `// TODO: Story 1.2` placeholder Swift files; they trigger lint rules that don't exist yet (Story 1.8) and clutter diffs.
- `.swiftformat`, `.swiftlint.yml`, `.github/workflows/ci.yml` — Story 1.8 ships these (per Epic 1 summary). This story does NOT touch CI configuration.
- `scripts/create-signing-ca.sh`, `scripts/setup-trust.sh`, `assets/auricle-root-ca.cer`, the code-signing identity, and the release script — Epic 9, Story 9.3 + 9.4 ship these (moved out of Epic 1 per the post-party-mode revision, epics.md line 596). Debug builds sign ad-hoc via `CODE_SIGN_IDENTITY = -` in `config/Debug.xcconfig`, which is all this story needs; the per-Mac trust workflow does not exist yet.
- `PermissionChecker` scaffold — Epic 5, Story 5.1 ships this where it's first exercised (per epics.md line 596).
- SQLite schema, `StateStore`, GRDB migrations — Story 1.4.
- `AtomicWriter`, `MeetingID`, `CanonicalTranscript`, `Codable+Dialects`, `Core/Config.swift` — Story 1.2.
- `Log` facade, sensitivity tagging — Story 1.3.
- `Orchestrator`, `StageRunner`, `CrashRecovery`, `RetentionScheduler` — Story 1.5.
- `Telemetry.record(...)`, `StageEventLogger` — Story 1.6.
- CLI verb implementations (`status`, `__internal-stage`, etc.) — Story 1.7.
- Sparkle integration — v1.1, Story 10.7. Reference it as a comment only.

### `Package.swift` Skeleton

This is the authoritative starting shape. **Adjust dependency versions to latest stable at scaffold time** but DO NOT remove or rename targets.

```swift
// swift-tools-version: 5.10
// AuricleKit — single SwiftPM library, 25 modular targets per AR-INIT-5.
// Module boundaries are the architecture: cross-target imports declared here are
// the ONLY allowed imports. SwiftPM rejects the build on accidental cross-edges.
//
// MARK: - Deferred to v1.1 (AR-INIT-2)
// Sparkle: https://github.com/sparkle-project/Sparkle.git from: "2.6.0"

import PackageDescription

let package = Package(
    name: "AuricleKit",
    platforms: [.macOS(.v14)],
    products: [
        // One library product per source target — Xcode targets link these by name.
        .library(name: "Core", targets: ["Core"]),
        .library(name: "State", targets: ["State"]),
        .library(name: "Telemetry", targets: ["Telemetry"]),
        .library(name: "Orchestrator", targets: ["Orchestrator"]),
        .library(name: "Permissions", targets: ["Permissions"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "TranscriberInterface", targets: ["TranscriberInterface"]),
        .library(name: "DiarizerInterface", targets: ["DiarizerInterface"]),
        .library(name: "SummarizerInterface", targets: ["SummarizerInterface"]),
        .library(name: "AIReviewerInterface", targets: ["AIReviewerInterface"]),
        .library(name: "CalendarInterface", targets: ["CalendarInterface"]),
        .library(name: "Transcribe", targets: ["Transcribe"]),
        .library(name: "Diarize", targets: ["Diarize"]),
        .library(name: "Attribute", targets: ["Attribute"]),
        .library(name: "Summarize", targets: ["Summarize"]),
        .library(name: "ClaudeSummarizer", targets: ["ClaudeSummarizer"]),
        .library(name: "ClaudeAIReviewers", targets: ["ClaudeAIReviewers"]),
        .library(name: "ReviewDiarization", targets: ["ReviewDiarization"]),
        .library(name: "WhisperKitTranscriber", targets: ["WhisperKitTranscriber"]),
        .library(name: "WhisperKitDiarizer", targets: ["WhisperKitDiarizer"]),
        .library(name: "GoogleCalendarSource", targets: ["GoogleCalendarSource"]),
        .library(name: "VaultGlossary", targets: ["VaultGlossary"]),
        .library(name: "Persist", targets: ["Persist"]),
        .library(name: "Verify", targets: ["Verify"]),
        .library(name: "Notifications", targets: ["Notifications"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        // === Cross-cutting ===
        .target(name: "Core", dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]),
        .target(name: "State", dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Telemetry", dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Orchestrator", dependencies: ["Core", "State", "Telemetry", "Permissions"]),
        .target(name: "Permissions", dependencies: ["Core"]),

        // === Capture ===
        .target(name: "Capture", dependencies: ["Core", "State", "Telemetry", "Permissions"]),

        // === Strategy interfaces (protocol-only — no concrete deps) ===
        .target(name: "TranscriberInterface", dependencies: ["Core"]),
        .target(name: "DiarizerInterface", dependencies: ["Core"]),
        .target(name: "SummarizerInterface", dependencies: ["Core"]),
        .target(name: "AIReviewerInterface", dependencies: ["Core", "DiarizerInterface", "TranscriberInterface"]),
        .target(name: "CalendarInterface", dependencies: ["Core"]),

        // === Stages ===
        .target(name: "Transcribe", dependencies: ["Core", "State", "Telemetry", "TranscriberInterface", "DiarizerInterface"]),
        .target(name: "Diarize", dependencies: ["Core", "State", "Telemetry", "DiarizerInterface"]),
        .target(name: "Attribute", dependencies: ["Core", "State", "Telemetry"]),
        .target(name: "Summarize", dependencies: ["Core", "State", "Telemetry", "SummarizerInterface", "CalendarInterface", "VaultGlossary"]),
        .target(name: "ReviewDiarization", dependencies: ["Core", "State", "Telemetry", "AIReviewerInterface"]),
        .target(name: "Persist", dependencies: ["Core", "State", "Telemetry"]),
        .target(name: "Verify", dependencies: ["Core", "State", "Telemetry"]),
        .target(name: "Notifications", dependencies: ["Core", "State"]),

        // === Concrete strategies ===
        .target(name: "ClaudeSummarizer", dependencies: ["Core", "SummarizerInterface", "VaultGlossary"]),
        .target(name: "ClaudeAIReviewers", dependencies: ["Core", "AIReviewerInterface"]),
        .target(name: "WhisperKitTranscriber", dependencies: [
            "Core", "TranscriberInterface",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .target(name: "WhisperKitDiarizer", dependencies: [
            "Core", "DiarizerInterface",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .target(name: "GoogleCalendarSource", dependencies: ["Core", "CalendarInterface"]),
        .target(name: "VaultGlossary", dependencies: ["Core"]),

        // === Test support ===
        .target(name: "TestSupport", dependencies: ["Core"]),

        // === Test targets (one per source target) ===
        .testTarget(name: "CoreTests", dependencies: ["Core", "TestSupport"]),
        .testTarget(name: "StateTests", dependencies: ["State", "TestSupport"]),
        .testTarget(name: "TelemetryTests", dependencies: ["Telemetry", "TestSupport"]),
        .testTarget(name: "OrchestratorTests", dependencies: ["Orchestrator", "TestSupport"]),
        .testTarget(name: "PermissionsTests", dependencies: ["Permissions", "TestSupport"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "TestSupport"]),
        .testTarget(name: "TranscriberInterfaceTests", dependencies: ["TranscriberInterface", "TestSupport"]),
        .testTarget(name: "DiarizerInterfaceTests", dependencies: ["DiarizerInterface", "TestSupport"]),
        .testTarget(name: "SummarizerInterfaceTests", dependencies: ["SummarizerInterface", "TestSupport"]),
        .testTarget(name: "AIReviewerInterfaceTests", dependencies: ["AIReviewerInterface", "TestSupport"]),
        .testTarget(name: "CalendarInterfaceTests", dependencies: ["CalendarInterface", "TestSupport"]),
        .testTarget(name: "TranscribeTests", dependencies: ["Transcribe", "TestSupport"]),
        .testTarget(name: "DiarizeTests", dependencies: ["Diarize", "TestSupport"]),
        .testTarget(name: "AttributeTests", dependencies: ["Attribute", "TestSupport"]),
        .testTarget(name: "SummarizeTests", dependencies: ["Summarize", "TestSupport"]),
        .testTarget(name: "ClaudeSummarizerTests", dependencies: ["ClaudeSummarizer", "TestSupport"]),
        .testTarget(name: "ClaudeAIReviewersTests", dependencies: ["ClaudeAIReviewers", "TestSupport"]),
        .testTarget(name: "ReviewDiarizationTests", dependencies: ["ReviewDiarization", "TestSupport"]),
        .testTarget(name: "WhisperKitTranscriberTests", dependencies: ["WhisperKitTranscriber", "TestSupport"]),
        .testTarget(name: "WhisperKitDiarizerTests", dependencies: ["WhisperKitDiarizer", "TestSupport"]),
        .testTarget(name: "GoogleCalendarSourceTests", dependencies: ["GoogleCalendarSource", "TestSupport"]),
        .testTarget(name: "VaultGlossaryTests", dependencies: ["VaultGlossary", "TestSupport"]),
        .testTarget(name: "PersistTests", dependencies: ["Persist", "TestSupport"]),
        .testTarget(name: "VerifyTests", dependencies: ["Verify", "TestSupport"]),
        .testTarget(name: "NotificationsTests", dependencies: ["Notifications", "TestSupport"]),
    ]
)
```

**Critical correctness checks for the manifest:**
- `Capture` MUST NOT depend on `Transcribe` — they live in separate subprocesses per AR-PIPE-1; `Capture` is GUI-process, `Transcribe` is subprocess-spawned. The pipeline contract is via SQLite + cache-dir, not an in-process method call.
- `Orchestrator` depends on `Core, State, Telemetry, Permissions` ONLY — no strategy interfaces, no concrete strategies (per Architecture §Module Boundaries graph). The orchestrator dispatches subprocesses via `SubprocessDispatcher` (spawning `auricle-cli __internal-stage <stage>`); concrete strategies are wired in the per-binary composition root (`AuricleApp.swift`, `auricle-cli/main.swift`) and instantiated inside subprocess stage entry points. The orchestrator never sees a `SummarizerStrategy` instance.
- `AIReviewerInterface` depends on `Core, DiarizerInterface, TranscriberInterface` (per arch line 2530) — it consumes both transcript and diarization artifact shapes (AR-AI-1).
- `Summarize` depends on `VaultGlossary` because `Sources/Summarize/GlossaryInjector.swift` (arch §Repository Layout, line 2311) lives in the Summarize target and injects vault-glossary terms into the Claude prompt.
- `ClaudeSummarizer` depends on `VaultGlossary` because the prompt builder injects the glossary (per AR-SUM-5 + Decision 3.2).
- `WhisperKitTranscriber` and `WhisperKitDiarizer` are SEPARATE targets even though they share WhisperKit; they ship in one subprocess per AR-PIPE-1, but the composition is at the binary level (the `transcribe` stage subprocess imports both), not at the SwiftPM target level. Keep them separate so Story 1.8's lint can detect cross-edges.
- `Telemetry` and `State` both link `GRDB.swift` because the telemetry table writes are partitioned per AR-DATA-4 — `Telemetry` writes to the `telemetry` table, `State` writes to `meetings` + `stage_events`. Two writers, two targets, no shared connection across module boundaries.

### Target Dependency Matrix (the ONLY allowed cross-edges)

If a target needs an edge not listed here, that's an architecture revision — escalate, do not silently add.

| Target | Allowed dependencies | Rationale |
|---|---|---|
| `Core` | `TOMLKit` | Config loader + primitives. No Apple framework deps beyond Foundation. |
| `State` | `Core`, `GRDB.swift` | Single SQL writer for `meetings`+`stage_events`+`retention_timers` (AR-DATA-4). |
| `Telemetry` | `Core`, `GRDB.swift` | Single SQL writer for `telemetry` table (AR-DATA-4). |
| `Orchestrator` | `Core`, `State`, `Telemetry`, `Permissions` | Dispatches subprocesses; never directly invokes strategy methods. Concrete strategies are wired in composition roots, not seen by Orchestrator. (Per Architecture §Module Boundaries graph.) |
| `Permissions` | `Core` | TCC + ScreenCaptureKit checks scaffold (impl in Epic 5). |
| `Capture` | `Core`, `State`, `Telemetry`, `Permissions` | In-process stage. NOT a depender of `Transcribe`. |
| `TranscriberInterface` | `Core` | Protocol-only target. |
| `DiarizerInterface` | `Core` | Protocol-only target. |
| `SummarizerInterface` | `Core` | Protocol-only target (AR-SUM-1). |
| `AIReviewerInterface` | `Core`, `DiarizerInterface`, `TranscriberInterface` | Protocol family per AR-AI-1; consumes diarization + transcript artifact shapes. |
| `CalendarInterface` | `Core` | Protocol-only target. |
| `Transcribe` | `Core`, `State`, `Telemetry`, `TranscriberInterface`, `DiarizerInterface` | Subprocess stage; combines transcribe+diarize per AR-PIPE-1. |
| `Diarize` | `Core`, `State`, `Telemetry`, `DiarizerInterface` | Diarization stage (some flows separate; protocol shared). |
| `Attribute` | `Core`, `State`, `Telemetry` | In-process stage; UI lives in `App/Auricle/`, view model in `Core/` per epics.md line 590(h). |
| `Summarize` | `Core`, `State`, `Telemetry`, `SummarizerInterface`, `CalendarInterface`, `VaultGlossary` | Subprocess stage; consumes calendar.json. `Summarize/GlossaryInjector.swift` (arch line 2311) injects vault-glossary terms into the prompt. |
| `ReviewDiarization` | `Core`, `State`, `Telemetry`, `AIReviewerInterface` | Subprocess stage (AR-AI-3). |
| `Persist` | `Core`, `State`, `Telemetry` | In-process stage; owns `VaultWriter` + `FrontmatterRenderer` + `FilenameResolver` (AR-PAT-4). |
| `Verify` | `Core`, `State`, `Telemetry` | In-process; owns `Verifier` actor (AR-FAIL-4). |
| `Notifications` | `Core`, `State` | In-process; UNUserNotificationCenter integration (Epic 8). |
| `ClaudeSummarizer` | `Core`, `SummarizerInterface`, `VaultGlossary` | Concrete strategy; needs glossary for prompt injection. |
| `ClaudeAIReviewers` | `Core`, `AIReviewerInterface` | Concrete strategy bundle for diarization+transcription reviewers. |
| `WhisperKitTranscriber` | `Core`, `TranscriberInterface`, `WhisperKit` | Concrete strategy. |
| `WhisperKitDiarizer` | `Core`, `DiarizerInterface`, `WhisperKit` | Concrete strategy. |
| `GoogleCalendarSource` | `Core`, `CalendarInterface` | Concrete strategy; OAuth+HTTP impl in Epic 3. |
| `VaultGlossary` | `Core` | Glossary builder + injector + jargon strategy (Epic 3). |
| `TestSupport` | `Core` | Test fixtures + `TestComposition` per AR-PAT-5. |

### Composition Root Dependency List (for Xcode target wiring)

The SwiftPM library products that each Xcode target should link:

**`AuricleApp` Xcode target** (the GUI composition root per AR-PAT-5; lives at `App/Auricle/AuricleApp.swift`):
- `Core`, `State`, `Telemetry`, `Orchestrator`, `Permissions`, `Capture`
- All five `*Interface` targets
- All stage targets: `Transcribe`, `Diarize`, `Attribute`, `Summarize`, `ReviewDiarization`, `Persist`, `Verify`, `Notifications`
- All concrete strategies: `ClaudeSummarizer`, `ClaudeAIReviewers`, `WhisperKitTranscriber`, `WhisperKitDiarizer`, `GoogleCalendarSource`
- `VaultGlossary`

**`auricle-cli` Xcode target** (the CLI composition root per AR-PAT-5; lives at `App/auricle-cli/main.swift`):
- Same library list as AuricleApp (the CLI exposes every stage per AR-PIPE-1, so it needs them all)
- swift-argument-parser SPM dependency (the CLI is the only consumer; declared at the Xcode-target level, not in the SwiftPM manifest)

### Critical architectural commitments this story locks in

| Commitment | What this story does | Verification |
|---|---|---|
| AR-INIT-1 | Hybrid SwiftPM library + Tuist-generated Xcode project | Repo layout matches; both schemes build; `.xcodeproj` untracked and regenerable |
| AR-INIT-2 | External SPM dependencies declared (Sparkle deferred) | `Package.swift` dependencies array |
| AR-INIT-3 | Build config in plain text: xcconfigs + Info.plist + entitlements + URL scheme | `config/*.xcconfig`, `plutil -lint`, `codesign -dv --entitlements -` |
| AR-INIT-6 | Toolchain pinned in `mise.toml` | `mise install` succeeds on a clean checkout |
| AR-PAT-11 | No GUI-required steps in this story | Every task is a shell command or a file write |
| AR-INIT-5 | Exact 25-target list + matching tests + TestSupport | `Package.swift` targets array |
| NFR-S2 | Stable bundle ID `com.auricle.app` | Info.plist `CFBundleIdentifier` |
| NFR-M7 | `Package.resolved` committed for reproducible builds | `.gitignore` does NOT exclude it |
| UX-DR44 | Info.plist usage descriptions in user voice (verbatim text per Decision 4.4) | Info.plist string keys |

### Project Structure Notes

The directory layout produced by this story is the canonical layout for the entire project. Every later story adds files INTO the existing `Sources/<Target>/` and `Tests/<Target>Tests/` directories — no story restructures the tree.

**One detail-but-load-bearing point:** `App/Auricle.xcodeproj` is a build artifact. It is generated by `tuist generate` from `Project.swift` and is gitignored — hand-rolling `project.pbxproj` is fragile, and hand-editing it afterwards is worse. Project changes are made by editing `Project.swift` (structure) or `config/*.xcconfig` (settings) and regenerating; both produce reviewable plain-text diffs in PRs. If you open the project in Xcode and change a setting through the UI, your change is destroyed on the next `tuist generate` — make the change in the xcconfig instead.

**Detected variances from a "pure SwiftPM" world:**
- The two executable targets live in the Xcode project, NOT as `executableTarget` declarations in `Package.swift`. This is intentional per Architecture §Selected Approach: SwiftPM gives us module boundary enforcement; Xcode gives us `.app` bundle output, code signing, entitlements, and Info.plist. Mixing pure-SwiftPM executables here would force `swift build` to produce binaries that lack the macOS-app machinery — and SwiftPM still cannot emit a `.app` bundle, which is what TCC permission stability (NFR-S2) depends on.
- The CLI binary `auricle-cli` lives at `App/auricle-cli/` (Xcode target sources), NOT at `Sources/auricle-cli/` as Architecture §Repository Layout's example diagram shows. The diagram is illustrative; AR-INIT-5's directory list is authoritative ("`App/auricle-cli/`"). If you find yourself confused, AR-INIT-5 wins.

### References

- [Source: _bmad-output/planning-artifacts/epics.md#Story 1.1: Project Initialization (Xcode + SwiftPM Hybrid)] — primary acceptance criteria
- [Source: _bmad-output/planning-artifacts/epics.md#Project Initialization & Starter Template] — AR-INIT-1 through AR-INIT-5 (lines 233–239)
- [Source: _bmad-output/planning-artifacts/epics.md#Epic 1: Foundation — Pipeline State + Atomic-Write Backbone] — Epic 1 framing + scope boundary (lines 592–606, 803–805)
- [Source: _bmad-output/planning-artifacts/epics.md#Epic 1 summary] — story sequencing + scope confirmation (lines 1113–1120)
- [Source: _bmad-output/planning-artifacts/epics.md#Interaction Patterns] — UX-DR44 verbatim Info.plist usage description strings (line 377)
- [Source: _bmad-output/planning-artifacts/architecture.md#Selected Approach: Hybrid SwiftPM Library + Xcode App Project] — selected structure + initialization recipe (lines 167–227)
- [Source: _bmad-output/planning-artifacts/architecture.md#Repository Layout] — canonical directory tree (lines 1864–1889)
- [Source: _bmad-output/planning-artifacts/architecture.md#Composition Roots] — composition-root rules per AR-PAT-5 (lines 1905–1913)
- [Source: _bmad-output/planning-artifacts/architecture.md#SwiftPM Target Names] — target naming conventions (lines 1816–1822)
- [Source: _bmad-output/planning-artifacts/architecture.md#Test Organization] — one test target per source target (lines 1897–1904)
- [Source: _bmad-output/planning-artifacts/architecture.md#Technical Constraints & Dependencies] — macOS 14+, arm64, no sandbox, locked stack (lines 66–98)
- [Source: _bmad-output/planning-artifacts/prd.md#NFR-S2] — bundle ID stability for TCC permissions

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5 (claude-sonnet-5), via Claude Code

### Debug Log References

- Task 0 spike: `tuist generate --no-open` + `xcodebuild build` for a minimal
  `App/` project consuming a parent-directory SwiftPM package — passed after
  adding `import ProjectDescription` to `Tuist.swift` (see deviation below).
- `swift build` / `swift test` full-package runs — see Completion Notes for the
  empty-target findings that drove `ManifestPlaceholder.swift` and the one
  `CoreTests` smoke test.
- `xcodebuild -scheme AuricleApp build` and `-scheme auricle-cli build` —
  both green; `auricle-cli` failed once on `'main' attribute cannot be used in
  a module that contains top-level code` until `main.swift` was renamed to
  `AuricleCLI.swift`.
- Reproducibility proof: `rm -rf App/Auricle.xcodeproj && tuist generate
  --no-open && xcodebuild -scheme AuricleApp build` — exit 0.
- `git ls-files --error-unmatch App/Auricle.xcodeproj` — exit 1 (untracked), as
  required.
- Cross-import spot check: `import Transcribe` added to `Sources/Capture/`,
  built with `swift build --explicit-target-dependency-import-check error` →
  `error: Target Capture imports another target (Transcribe) in the package
  without declaring it a dependency.` Plain `swift build` (no flag) does
  **not** reject this import — see Completion Notes.
- `codesign -dv` and `codesign -d --entitlements -` on the built
  `AuricleApp.app` — `Identifier=com.auricle.app`, hardened runtime flag set,
  `com.apple.security.device.audio-input` present, no sandbox entitlement.
- `plutil -lint` on `Info.plist` and `Auricle.entitlements` — both OK.

### Completion Notes List

All four ACs and all eleven tasks are implemented and independently verified
by running the actual commands (not just constructing files). Five points
where the installed toolchain (Xcode 26.4.1 / Swift 6.3.1 / Tuist 4.208.0)
diverged from what the story's literal text assumed, each resolved and worth
carrying into later stories:

1. **`Tuist.swift` needs `import ProjectDescription`.** The one-line skeleton
   in Task 6 (`let tuist = Tuist(project: .tuist(...))`) does not compile
   without the import; added it.

2. **`Project.swift` lives in `App/`, not at the repo root, and a
   `Workspace.swift` is required.** Task 6 says "Project.swift at repo root,"
   but Tuist places the generated `.xcodeproj` in the same directory as the
   `Project.swift` that declares it (confirmed via the Task 0 spike and by
   direct experiment). Repo-root `Project.swift` would have produced
   `Auricle.xcodeproj` at the repo root, not `App/Auricle.xcodeproj`, which
   AC2 and Task 11 both require verbatim. Placed `Project.swift` at
   `App/Project.swift` (paths inside it are App/-relative:
   `Auricle/Info.plist`, `Auricle/Auricle.entitlements`, `Auricle/**`,
   `auricle-cli/**`, `../config/Debug.xcconfig`) and added a `Workspace.swift`
   at the repo root (`projects: ["App"]`) — without it, `tuist generate` run
   from the repo root silently ignores `App/Project.swift` and instead
   auto-generates a preview project for the raw `Package.swift` (this is also
   why `AuricleKit.xcodeproj` and `Auricle.xcworkspace` appear at the repo
   root as side effects; both are gitignored via the new `*.xcodeproj/` /
   `*.xcworkspace/` rules).

3. **A target that's the target of a `.library` product cannot have zero
   source files on this toolchain.** AC1 asks for "no source files in any
   target (empty target compilation passes)," but `swift build` hard-errors
   with `target 'X' referenced in product 'X' is empty` for every one of the
   25 library products with nothing but a `.gitkeep` in its directory (a
   target that is *only* a dependency, never a product, tolerates this fine —
   it's specifically the product-target combination current SwiftPM rejects).
   Added `Sources/<Target>/ManifestPlaceholder.swift` — a comment-only file,
   zero lines of code — to all 26 source targets (25 + TestSupport) stating
   the constraint. The `.gitkeep` files created alongside it in Task 5 were
   removed once the placeholder existed: git only needs one tracked file to
   keep a directory, and `ManifestPlaceholder.swift` already is that file (see
   the removal note near the end of this section).

4. **`swift test` needs at least one real test in the whole package, or it
   hard-fails with "no tests found."** AC1's "empty test suites pass" holds
   for 24 of the 25 test targets (each compiles as a genuinely empty
   `.gitkeep`-only directory and contributes 0 tests, 0 failures). The 25th,
   `CoreTests`, carries one intentionally trivial `@Test` — the minimum
   needed so the package-wide test runner doesn't itself fail with "no tests
   found." Documented in a comment on that test rather than left unexplained.

5. **Plain `swift build` does not enforce SwiftPM module boundaries by
   default.** This is the one deviation I'd flag as a real risk rather than a
   cosmetic toolchain gap: AR-INIT-1 / AR-PAT-10 rest on "the build system
   rejects any accidental import," and Task 11's spot-check assumes a bare
   `swift build` proves it. Empirically, a `Sources/Capture/` file with
   `import Transcribe` (never declared as a `Capture` dependency) builds
   clean with plain `swift build`. The rejection only happens with
   `swift build --explicit-target-dependency-import-check error` (confirmed:
   `error: Target Capture imports another target (Transcribe) in the package
   without declaring it a dependency.`). I ran the spot-check with that flag
   and then deleted the test file per the task's instructions, so the manifest
   itself is unaffected — but nothing in this story's file set makes the
   check happen automatically. **Story 1.8 (lint/CI) should bake
   `--explicit-target-dependency-import-check error` into whatever `swift
   build` invocation CI runs**, or the module-boundary enforcement this whole
   scaffolding exists for is opt-in and silent by default.

Two minor, purely mechanical fixes beyond the deviations above:
- `App/auricle-cli/main.swift` → renamed to `App/auricle-cli/AuricleCLI.swift`
  — Swift disallows `@main` in a file named `main.swift` ("cannot be used in a
  module that contains top-level code"); this is a compiler rule, not a
  design choice. The file's content is otherwise exactly what Task 9 asked
  for.
- `CODE_SIGN_ENTITLEMENTS` in `config/Shared.xcconfig` is
  `Auricle/Auricle.entitlements` (App/-relative, i.e. relative to
  `App/Auricle.xcodeproj`'s `SRCROOT`), not `App/Auricle/Auricle.entitlements`
  as literally written in Task 7 — same repo-root-vs-App/-root reasoning as
  point 2. Verified by inspecting the codesigned binary's embedded
  entitlements, which come back correct.

`swift build` / `swift test` emit 24 warnings of the form `Source files for
target XTests should be located under 'Tests/XTests'…` — one per test target
that has nothing but `Tests/<Target>Tests/.gitkeep` in it (every test target
except `CoreTests`). This is SwiftPM's generic "this target looks empty"
warning, triggered because `.gitkeep` is a dotfile and doesn't count as a
source file; it is expected and benign until each target's own story adds
real tests, not a regression to chase.

`.xcode-version` at the repo root pins Xcode 26.4.1 (bundling Swift 6.3.1),
the toolchain this story was built and verified against — `mise.toml` pins
tuist/swiftformat/swiftlint but nothing previously pinned Xcode/Swift itself,
which NFR-M7's byte-identical-rebuild guarantee also depends on. mise.toml
otherwise pins the latest available exact versions at scaffold time:
tuist 4.208.0, swiftformat 0.63.0, swiftlint 0.65.1. `tuist install` was run
once to resolve Tuist's own package cache (cleared an "outdated dependencies"
warning); this is routine and not itself a deviation.

`Sources/<Target>/.gitkeep` was removed from all 26 library targets — once
`ManifestPlaceholder.swift` exists there, `.gitkeep` is redundant (git only
needs one tracked file to keep a directory). `Tests/<Target>Tests/.gitkeep`
is left alone: those directories are still genuinely empty (see the warning
note above).

Nothing in Sources/ or Tests/ beyond `ManifestPlaceholder.swift`, the 25
`Tests/<Target>Tests/.gitkeep` files, and the one `CoreTests` smoke test
contains real code — scope for Stories 1.2–1.7 is untouched.

### File List

**Root manifests:** `Package.swift`, `Package.resolved`, `Tuist.swift`,
`Workspace.swift`, `mise.toml`, `.xcode-version`, `.gitignore` (extended,
pre-existing Python-oriented file)

**Xcode/Tuist half:** `App/Project.swift`, `App/Auricle/Info.plist`,
`App/Auricle/Auricle.entitlements`, `App/Auricle/AuricleApp.swift`,
`App/auricle-cli/AuricleCLI.swift`, `config/Shared.xcconfig`,
`config/Debug.xcconfig`, `config/Release.xcconfig`

**SwiftPM targets:** `Sources/<Target>/ManifestPlaceholder.swift` for all 26
library targets (no `.gitkeep` — the placeholder file itself keeps the
directory tracked):
(`Core`, `State`, `Telemetry`, `Orchestrator`, `Permissions`, `Capture`,
`TranscriberInterface`, `DiarizerInterface`, `SummarizerInterface`,
`AIReviewerInterface`, `CalendarInterface`, `Transcribe`, `Diarize`,
`Attribute`, `Summarize`, `ReviewDiarization`, `Persist`, `Verify`,
`Notifications`, `ClaudeSummarizer`, `ClaudeAIReviewers`,
`WhisperKitTranscriber`, `WhisperKitDiarizer`, `GoogleCalendarSource`,
`VaultGlossary`, `TestSupport`)

**SwiftPM test targets:** `Tests/<Target>Tests/.gitkeep` for all 25 test
targets; `Tests/CoreTests/PackageScaffoldingTests.swift` additionally (the one
real test — see Completion Notes point 4)

**Placeholders:** `scripts/.gitkeep`, `assets/.gitkeep`

**Planning artifacts (status tracking only):**
`_bmad-output/implementation-artifacts/1-1-project-initialization-xcode-swiftpm-hybrid.md`
(this file — Status field + this section),
`_bmad-output/implementation-artifacts/sprint-status.yaml` (story status)

Nothing was committed — all of the above are working-tree changes, per
standing instructions not to commit without being asked.

## Review Triage Log

| # | Finding | Verdict | Route | Evidence |
|---|---------|---------|-------|----------|
| 1 | `Package.swift` header comment claims unconditional cross-edge rejection (Blind Hunter + Verification Gap) | medium | patch | Verified: plain `swift build` does not reject an undeclared cross-target import (confirmed via the Debug Log's own `import Transcribe` regression in `Capture`); only `--explicit-target-dependency-import-check error` does. The header comment (lines 3-4) states enforcement unconditionally. |
| 2 | `swift build`/`swift test` emit 24 unaddressed "should be located under..." warnings (Blind Hunter) | low | patch | Verified by independently running `swift build` and `swift test`: one warning per empty test target (24 of 25, all but `CoreTests`), undocumented in Completion Notes. |
| 3 | `Package.swift` target/product declaration order diverges from Task 2's literal stage order (Blind Hunter) | low | patch | Verified: `ReviewDiarization` sits after `Summarize` instead of after `Notifications`; products array interleaves stages and concrete strategies. Task 2 is checked `[x]` despite the literal order not matching. |
| 4 | Story status vocabulary (`in-review`) and sprint-status.yaml vocabulary (`review`) name the same state differently (Blind Hunter + Edge Case Hunter) | low | defer | Verified: each value is correct per its own file's documented enum, but the two files describing the same story state now disagree. Pre-existing mismatch between two BMAD tracking conventions, not introduced by this story's code. |
| 5 | `NSUserNotificationsUsageDescription`'s effect on the runtime permission prompt is asserted as settled fact but not independently confirmed (Blind Hunter) | maybe-false (medium if true) | defer | Could not verify Apple's current documented behavior for this key without a live device/doc check. If the key does not gate the prompt text as claimed, UX-DR44's locked copy silently never displays — real but not build/test-breaking. Settled by: requesting notification authorization on a macOS 14 build and confirming the shown description text. |
| 6 | Dead `.gitignore` rules (`*.xcodeproj/xcuserdata/`, `*.xcworkspace/xcuserdata/`) fully superseded by broader rules added later in the same file (Blind Hunter) | low | patch | Verified by reading the `.gitignore` diff: the broader `*.xcodeproj/` / `*.xcworkspace/` rules already exclude everything the narrower `xcuserdata/` rules match. |
| 7 | No pin on the Xcode/Swift toolchain version itself, though `mise.toml`'s own stated rationale is NFR-M7 byte-identical rebuilds (Blind Hunter) | medium | patch | Verified: `mise.toml` pins tuist/swiftformat/swiftlint only; the Xcode/Swift version (26.4.1/6.3.1) used and verified exists only as Debug Log prose, unpinned in any repo file. |
| 8 | Redundant `.gitkeep` alongside `ManifestPlaceholder.swift` in all 26 `Sources/<Target>/` directories (Blind Hunter) | low | patch | Verified: `ManifestPlaceholder.swift` alone makes git track the directory; `.gitkeep` there is inert. The stated rationale ("kept for when the placeholder is eventually deleted") doesn't hold since real source files will make `.gitkeep` equally redundant at that point too. |
| 9 | File List entries `scripts/.gitkeep`, `assets/.gitkeep` have no matching Task bullet (Blind Hunter) | false | reject | AC4 explicitly requires both placeholder directories ("scripts/ (empty placeholder...)", "assets/ (empty placeholder...)") — the requirement traces to the Acceptance Criteria, just not restated in a Task bullet. |
| 10 | "Two documented exceptions" phrasing in Completion Notes could be read as two files instead of two categories spanning 27 files (Blind Hunter) | false | reject | The sentence and its surrounding context (which names both categories, `ManifestPlaceholder.swift` and the `CoreTests` smoke test) reads as two *categories*, and the full File List enumerates every actual file elsewhere in the same section — no reader is materially misled. |
| 11 | `AuricleApp.swift` has no `.onOpenURL` handler for the newly-registered `auricle://` scheme (Edge Case Hunter) | false | reject | Task 8 is explicit: the app shell is "NOTHING ELSE. No Orchestrator instantiation, no view models, no concrete strategies... implemented incrementally as later stories ship." URL-scheme click handling is explicitly Epic 8's scope (Notifier/NotificationDelegate), not this scaffolding-only story's. |
| 12 | `ManifestPlaceholder.swift` / `CoreTests` sentinel test flagged as load-bearing claims (Edge Case Hunter) | false | reject | Not a defect — the reviewer's own "claim" entries confirm these files are correctly necessary, which Completion Notes points 3-4 already document in full. |
| 13 | `Auricle.entitlements` lacks a distinct "notification entitlements" key alongside `com.apple.security.device.audio-input` (Edge Case Hunter) | false | reject | Task 8 is explicit that macOS has no entitlement key for `UNUserNotificationCenter` — authorization is runtime-requested and gated by `NSUserNotificationsUsageDescription` alone. `AuricleApp.swift`'s new comment documents this exact point. AC2's summary wording is loose but the implementation matches the more specific Task guidance. |
