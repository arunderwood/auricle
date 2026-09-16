# Story 1.1: Project Initialization (Xcode + SwiftPM Hybrid)

Status: ready-for-dev

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As Andrew (in builder mode),
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
- `assets/` (empty placeholder; populated in Epic 9 with `AndrewCodeSigningCA.cer`)
- `_bmad-output/` (already exists — planning artifacts)

**And** `.gitignore` excludes `.build/`, `.swiftpm/`, `DerivedData/`, `xcuserdata/`, `App/Auricle.xcodeproj/`, `.tuist/`, `Derived/`
**And** `git ls-files --error-unmatch App/Auricle.xcodeproj` fails — the generated project is not tracked (AR-INIT-1, enforced in CI by Story 1.8)
**And** `Package.resolved` IS committed (listed in `.gitignore` as a comment for clarity, but tracked in git for reproducible builds per NFR-M7)

## Tasks / Subtasks

- [ ] **Task 0: Tuist local-package spike** (gates every later task — do NOT start Task 1 until this passes)
  - [ ] Install the toolchain: `mise install` if `mise.toml` exists, otherwise `brew install tuist` (Task 6 writes `mise.toml` properly)
  - [ ] In a scratch directory OUTSIDE the repo, create a minimal `Package.swift` with one library target, and an `App/Project.swift` declaring one `.app` target with `packages: [.local(path: ".")]` and `dependencies: [.package(product: "TheLibrary")]`
  - [ ] Run `tuist generate --no-open && xcodebuild -scheme <app> build` — must exit 0
  - [ ] **If this fails:** stop. Fall back to XcodeGen (already installed, 2.46.0) with an identical `config/*.xcconfig` split — only the manifest language changes, because no build setting lives in the manifest. Record the failure and the deviation from AR-INIT-1 in the Dev Agent Record, and tell the user before proceeding.
  - [ ] Delete the scratch directory. Do NOT commit it.

  **Why this gate exists:** the Tuist manifest API used by Tasks 6–8 is verified against Tuist's `ProjectDescription` sources (`Product.app`, `Product.commandLineTool`, `Package.local(path:)`, `TargetDependency.package(product:)`, `InfoPlist.file(path:)`, `Entitlements.file(path:)`, `Configuration.debug(name:settings:xcconfig:)` all exist as written). What is NOT verified is this specific arrangement — a project in `App/` consuming a SwiftPM package at the repository root. Thirty minutes here beats discovering it at Task 6.

- [ ] **Task 1: Initialize SwiftPM package** (AC: #1)
  - [ ] Run `swift package init --type library --name AuricleKit` at repo root (do NOT use `--type executable`; the manifest is the library; executables live in the Xcode project per AR-INIT-1)
  - [ ] Delete the auto-generated `Sources/AuricleKit/AuricleKit.swift` and `Tests/AuricleKitTests/AuricleKitTests.swift` placeholder files — they belong to no real target
  - [ ] Edit `Package.swift` per the manifest skeleton in **Dev Notes → Package.swift Skeleton** below
  - [ ] Set `swift-tools-version: 5.10` on line 1 (required for Swift Testing per Architecture §Testing Framework)
  - [ ] Set `platforms: [.macOS(.v14)]` (per AR-INIT-3 deployment target)
- [ ] **Task 2: Declare all 26 library targets in `Package.swift`** (AC: #1)
  - [ ] Declare 25 library targets per AR-INIT-5 in this order: cross-cutting first (`Core`, `State`, `Telemetry`, `Orchestrator`, `Permissions`), then capture (`Capture`), then interfaces (`TranscriberInterface`, `DiarizerInterface`, `SummarizerInterface`, `AIReviewerInterface`, `CalendarInterface`), then stages (`Transcribe`, `Diarize`, `Attribute`, `Summarize`, `Persist`, `Verify`, `Notifications`, `ReviewDiarization`), then concrete strategies (`ClaudeSummarizer`, `ClaudeAIReviewers`, `WhisperKitTranscriber`, `WhisperKitDiarizer`, `GoogleCalendarSource`, `VaultGlossary`)
  - [ ] Declare the `TestSupport` library target (per AR-INIT-5 — test fixtures + composition root for tests, per Architecture §Test Organization)
  - [ ] For each target, create the source directory `Sources/<Target>/` even if empty (SwiftPM requires the directory to exist; empty directories are not committed by git unless a `.gitkeep` is added — see Task 5)
  - [ ] Wire dependency edges per **Dev Notes → Target Dependency Matrix** below — DO NOT add cross-edges that aren't listed (SwiftPM target boundaries are the architecture per AR-PAT-10 build-time enforcement)
  - [ ] Each library target sets `path: "Sources/<TargetName>"` explicitly (not strictly required since names match defaults, but explicit-is-better keeps grep findable)
- [ ] **Task 3: Declare 25 matching test targets in `Package.swift`** (AC: #1)
  - [ ] Declare `<Target>Tests` for every library target (25 total) — per AR-INIT-5 + Architecture §Test Organization "One test target per source target"
  - [ ] **EXCEPTION:** Interface-only targets (`TranscriberInterface`, `DiarizerInterface`, `SummarizerInterface`, `AIReviewerInterface`, `CalendarInterface`) may have `<Target>Tests` declared with a comment: `// Interface-only target — protocol declarations only; tests minimal/none. AR-PAT-1.` Still create the test target so the structure is uniform; later stories that ship the protocols add real tests.
  - [ ] Each test target depends on its corresponding source target + `TestSupport`
  - [ ] Each test target sets `path: "Tests/<TargetName>Tests"` explicitly
  - [ ] Each test target uses Swift Testing (no need to import XCTest at the manifest level; the framework is implicit in Swift 5.10+)
- [ ] **Task 4: Declare external SPM dependencies in `Package.swift`** (AC: #1)
  - [ ] WhisperKit: `https://github.com/argmaxinc/WhisperKit.git` — `from: "0.9.0"` (use latest stable at scaffold time; pin via `Package.resolved`)
  - [ ] GRDB.swift: `https://github.com/groue/GRDB.swift.git` — `from: "6.29.0"` (latest 6.x stable; do not jump to 7.x without architectural review of any breaking changes)
  - [ ] swift-argument-parser: `https://github.com/apple/swift-argument-parser.git` — `from: "1.5.0"`
  - [ ] TOMLKit: `https://github.com/LebJe/TOMLKit.git` — `from: "0.6.0"`
  - [ ] Sparkle: declare as a top-of-file comment: `// MARK: - Deferred to v1.1 (AR-INIT-2) — Sparkle: https://github.com/sparkle-project/Sparkle.git from: "2.6.0"`
  - [ ] Wire WhisperKit only into `WhisperKitTranscriber` and `WhisperKitDiarizer` targets
  - [ ] Wire GRDB.swift only into `State` and `Telemetry` targets (per Architecture §SQLite Layer "Depended on by the State target only" — Telemetry is the second authorized SQL writer per AR-PAT-4)
  - [ ] Wire swift-argument-parser into the `auricle-cli` Xcode target only (NOT into any SwiftPM library target; the CLI is the binding-contract surface per NFR-I7 and the parser is the executable-shell concern)
  - [ ] Wire TOMLKit only into `Core` (config loader lives in `Core/Config.swift` per Story 1.2)
- [ ] **Task 5: Create `Sources/<Target>/` and `Tests/<Target>Tests/` directories with `.gitkeep` placeholders** (AC: #1, #4)
  - [ ] For each of the 25 library targets: `mkdir -p Sources/<Target>` and add `Sources/<Target>/.gitkeep` (zero-byte file — git tracks empty directories only via at-least-one tracked file)
  - [ ] For `TestSupport`: `mkdir -p Sources/TestSupport` + `.gitkeep`
  - [ ] For each of the 26 test targets: `mkdir -p Tests/<Target>Tests` + `.gitkeep`
  - [ ] Verify `swift build` and `swift test` succeed against the empty package (this is AC1's "empty target compilation passes" gate — fail here means the manifest is wrong)
- [ ] **Task 6: Write `mise.toml`, `Tuist.swift`, and `Project.swift`** (AC: #2, #3)
  - [ ] `mise.toml` at repo root pinning exact versions of `tuist`, `swiftformat`, `swiftlint` (AR-INIT-6). Pin exact versions, not ranges — drift breaks NFR-M7's byte-identical-rebuild guarantee.
  - [ ] `Tuist.swift` at repo root: `let tuist = Tuist(project: .tuist(generationOptions: .options()))`
  - [ ] `Project.swift` at repo root: `packages: [.local(path: ".")]` — the root SwiftPM package
  - [ ] Declare target `AuricleApp`: `destinations: [.mac]`, `product: .app`, `bundleId: "com.auricle.app"`, `deploymentTargets: .macOS("14.0")`, `infoPlist: .file(path: "App/Auricle/Info.plist")`, `entitlements: .file(path: "App/Auricle/Auricle.entitlements")`, `sources: ["App/Auricle/**"]`, and one `.package(product:)` dependency per library it consumes (see **Dev Notes → Composition Root Dependency List** below)
  - [ ] Declare target `auricle-cli`: `destinations: [.mac]`, `product: .commandLineTool`, `sources: ["App/auricle-cli/**"]`, dependencies `.package(product:)` for swift-argument-parser plus every SwiftPM library product (CLI is the binding-contract surface; needs full library access per Architecture §Composition Roots)
  - [ ] Project-level `settings:` → `.settings(configurations: [.debug(name: .debug, xcconfig: "config/Debug.xcconfig"), .release(name: .release, xcconfig: "config/Release.xcconfig")], defaultSettings: .none)`
  - [ ] **`defaultSettings: .none` is load-bearing.** It stops Tuist injecting its own build settings, which would silently shadow the xcconfigs and make the plain-text files a lie.
  - [ ] Run `tuist generate --no-open`; confirm `App/Auricle.xcodeproj` appears
  - [ ] Confirm the generated project is ignored: `git status --porcelain` shows nothing under `App/` except the committed source directories
- [ ] **Task 7: Write `config/*.xcconfig` and `App/Auricle/Info.plist`** (AC: #2, #3)
  - [ ] `config/Shared.xcconfig`: `MACOSX_DEPLOYMENT_TARGET = 14.0`; `ARCHS = arm64`; `EXCLUDED_ARCHS = x86_64` (Apple Silicon only per Architecture §Technical Constraints "Apple Silicon only. M5 Max is reference hardware; M1 is the floor"); `ENABLE_HARDENED_RUNTIME = YES`; `PRODUCT_BUNDLE_IDENTIFIER = com.auricle.app`; `CODE_SIGN_ENTITLEMENTS = App/Auricle/Auricle.entitlements`; `SWIFT_VERSION = 5.10`
  - [ ] **Do NOT add `ENABLE_APP_SANDBOX` in any form.** The key must be absent, not set to `NO` — the sandbox conflicts with ScreenCaptureKit and vault writes per Architecture §Technical Constraints.
  - [ ] `config/Debug.xcconfig`: `#include "Shared.xcconfig"`; `CODE_SIGN_IDENTITY = -` (ad-hoc)
  - [ ] `config/Release.xcconfig`: `#include "Shared.xcconfig"`; `CODE_SIGN_IDENTITY = Auricle Code Signing`; `CODE_SIGN_STYLE = Manual`. That identity does not exist until Story 9.3 creates it, so Release will not sign yet — expected, and Epic 9's problem rather than this story's.
  - [ ] `App/Auricle/Info.plist` — hand-written XML, committed. Bundle identifier comes from `PRODUCT_BUNDLE_IDENTIFIER` via `$(PRODUCT_BUNDLE_IDENTIFIER)`; **DO NOT CHANGE** that value ever, per NFR-S2 (TCC permissions are keyed on bundle ID)
  - [ ] Set `LSUIElement = NO` (auricle is a normal app with a Dock icon and main window per UX-DR1, not a menu bar accessory; menu-bar item arrives in v1.1 per FR8)
  - [ ] Add `NSScreenCaptureUsageDescription` with verbatim string: `auricle records your meeting audio so it can transcribe what's said` (UX-DR44 — DO NOT paraphrase; user-voice copy is locked)
  - [ ] Add `NSMicrophoneUsageDescription` with verbatim string: `auricle captures your voice alongside the meeting so your contributions are in the notes`
  - [ ] Add `NSUserNotificationsUsageDescription` with verbatim string: `auricle pings you when a meeting is ready to review — usually just a click to confirm`
  - [ ] Add `CFBundleURLTypes` array with one entry: `CFBundleURLName = "com.auricle.app.url"`, `CFBundleURLSchemes = ["auricle"]` (per AR-INIT-3 + Architecture §Notification / URL Scheme Names — registers `auricle://` for notification-click handlers per AR-FAIL-5)
  - [ ] Verify both files parse: `plutil -lint App/Auricle/Info.plist`
- [ ] **Task 8: Write `App/Auricle/Auricle.entitlements`** (AC: #2)
  - [ ] Hand-written plist, committed at `App/Auricle/Auricle.entitlements`, containing `com.apple.security.device.audio-input` = `true`
  - [ ] Verify the entitlements file does NOT contain `com.apple.security.app-sandbox` (would break ScreenCaptureKit + vault writes)
  - [ ] `UNUserNotificationCenter` requires no entitlement key on macOS — authorization is requested at runtime and gated by `NSUserNotificationsUsageDescription`. Record that in a comment in `AuricleApp.swift` so the next reader does not go looking for a key that does not exist.
  - [ ] Verify it parses: `plutil -lint App/Auricle/Auricle.entitlements`
- [ ] **Task 9: Write minimal stub `@main` for AuricleApp + minimal swift-argument-parser scaffold for auricle-cli** (AC: #2)
  - [ ] `App/Auricle/AuricleApp.swift`: declare `@main struct AuricleApp: App { var body: some Scene { WindowGroup { Text("auricle") } } }` — NOTHING ELSE. No `Orchestrator` instantiation, no view models, no concrete strategies. The composition root per AR-PAT-5 is implemented incrementally as later stories ship.
  - [ ] `App/auricle-cli/main.swift`: declare `import ArgumentParser` + `@main struct AuricleCLI: AsyncParsableCommand { static let configuration = CommandConfiguration(commandName: "auricle", abstract: "Personal meeting notes pipeline") }` — NO subcommands yet. Story 1.7 ships the CLI scaffold with `status` + hidden `__internal-stage` per AR-PIPE-7.
- [ ] **Task 10: Write `.gitignore`** (AC: #4)
  - [ ] Add `.build/` (SwiftPM build output)
  - [ ] Add `.swiftpm/` (SwiftPM local cache + xcode-generated package files)
  - [ ] Add `DerivedData/` (Xcode build output)
  - [ ] Add `App/Auricle.xcodeproj/` — the generated Xcode project. Never committed; regenerate with `tuist generate` (AR-INIT-1). CI fails the build if it is tracked (Story 1.8).
  - [ ] Add `.tuist/` and `Derived/` (Tuist local cache and derived artifacts)
  - [ ] Add `xcuserdata/` (Xcode per-user state — `*.xcodeproj/xcuserdata/` and `*.xcworkspace/xcuserdata/`)
  - [ ] **DO NOT** add `Package.resolved` to `.gitignore` — it's committed for reproducible builds (NFR-M7). Add a comment in `.gitignore`: `# Package.resolved IS committed (reproducible builds per NFR-M7)`
  - [ ] Add `.DS_Store` (cosmetic; macOS junk)
  - [ ] Add `*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is NOT excluded — Xcode's auto-managed lockfile mirror is fine to commit alongside the SwiftPM root `Package.resolved`
- [ ] **Task 11: Verify the complete build chain works end-to-end** (AC: #1, #2, #4)
  - [ ] From repo root: `swift build` → must exit 0
  - [ ] From repo root: `swift test` → must exit 0 (no tests run, but no compile errors)
  - [ ] From repo root: `tuist generate --no-open` → must exit 0
  - [ ] From repo root: `xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp -destination 'platform=macOS,arch=arm64' build` → must exit 0
  - [ ] From repo root: `xcodebuild -project App/Auricle.xcodeproj -scheme auricle-cli -destination 'platform=macOS,arch=arm64' build` → must exit 0
  - [ ] Prove the project is reproducible from the manifest alone: `rm -rf App/Auricle.xcodeproj && tuist generate --no-open && xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp -destination 'platform=macOS,arch=arm64' build` → must exit 0. This is the whole point of AR-INIT-1; if it fails, the project is carrying state that lives nowhere in version control.
  - [ ] Confirm the generated project is untracked: `git ls-files --error-unmatch App/Auricle.xcodeproj` → must FAIL (non-zero exit)
  - [ ] Spot-check one cross-target import that should fail: in `Sources/Capture/.gitkeep` add a temporary `Sources/Capture/_TestImport.swift` containing `import Transcribe`; run `swift build`; confirm SwiftPM rejects the build with a "no such module" error (per AR-INIT-1 + AR-PAT-10 build-time enforcement); then DELETE the test file. **DO NOT COMMIT this verification artifact** — its existence is what we're proving the manifest *forbids*.

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
- `scripts/create-signing-ca.sh`, `scripts/setup-trust.sh`, `assets/AndrewCodeSigningCA.cer`, the code-signing identity, and the release script — Epic 9, Story 9.3 + 9.4 ship these (moved out of Epic 1 per the post-party-mode revision, epics.md line 596). Debug builds sign ad-hoc via `CODE_SIGN_IDENTITY = -` in `config/Debug.xcconfig`, which is all this story needs; the per-Mac trust workflow does not exist yet.
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

(to be filled by dev agent)

### Debug Log References

(to be filled by dev agent)

### Completion Notes List

(to be filled by dev agent)

### File List

(to be filled by dev agent)
