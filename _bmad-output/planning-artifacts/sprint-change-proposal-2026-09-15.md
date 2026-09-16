---
date: 2026-09-15
project: auricle
workflow: correct-course
trigger_story: 1-1-project-initialization-xcode-swiftpm-hybrid
scope_classification: moderate
status: proposed
artifacts_affected:
  - _bmad-output/planning-artifacts/architecture.md
  - _bmad-output/planning-artifacts/epics.md
  - _bmad-output/implementation-artifacts/1-1-project-initialization-xcode-swiftpm-hybrid.md
  - _bmad-output/implementation-artifacts/sprint-status.yaml
status: applied
applied: 2026-09-15
---

# Sprint Change Proposal — Eliminate GUI-Required Development Tasks

## 1. Issue Summary

### Problem statement

The approved plan requires Xcode's GUI to create and configure the project. Story 1.1 — the first
implementation story, and a hard dependency of all 89 others — cannot be completed by a development
agent, in CI, or over SSH. Three of its eleven tasks are GUI navigation sequences.

The same pattern recurs in Epic 9's distribution stories, where certificate creation is documented as
a Keychain Access walkthrough and the signing identity is set in Xcode's Signing & Capabilities pane.

### How it was discovered

Pre-implementation review of Story 1.1 (status `ready-for-dev`, never started). The repository contains
no Swift code; the trigger is a planning defect caught before any work was built on it.

### Evidence

Verbatim GUI-dependent steps, by artifact:

**Story 1.1** — `_bmad-output/implementation-artifacts/1-1-project-initialization-xcode-swiftpm-hybrid.md`

| Line | Text |
|---|---|
| 94 | "Use Xcode GUI: File > New > Project > macOS > App…" |
| 95 | "in Xcode, File > Add Package Dependencies > Add Local…" |
| 97 | "Add a second target: File > New > Target > macOS > Command Line Tool" |
| 99 | "Set Hardened Runtime ON (Signing & Capabilities > + Capability…)" |
| 102 | "Build Settings > Architectures > Standard Architectures" |
| 111 | "In Xcode: AuricleApp target > Signing & Capabilities > + Capability > add Microphone" |
| 363 | "The `App/Auricle.xcodeproj` is created via Xcode's GUI (because Xcode's project format is XML and hand-rolling it is fragile)." |

**architecture.md**

| Line | Text |
|---|---|
| 176 | "Only the executable shell, signing, and bundling require Xcode-GUI work" |
| 197–203 | "`# Then in Xcode:` / `File > New > Project > macOS > App`…" |
| 248 | "Generated via Keychain Access > Certificate Assistant > Create a Certificate" |
| 276–278 | "**Per-build signing (in Xcode):** Project's Signing & Capabilities pane: Signing Identity = …" |

**epics.md**

| Line | Text |
|---|---|
| 234 (AR-INIT-1) | Xcode project as a committed source artifact |
| 236 (AR-INIT-3) | "Xcode project configuration: Hardened Runtime ON, App Sandbox OFF…" |
| 3618 (Story 9.3) | "generated via Keychain Access > Certificate Assistant or `openssl`" |
| 3628 (Story 9.3) | "**Given** Xcode Signing & Capabilities" |

### Explicitly NOT part of this issue

The sweep found many other GUI references that are **end-user runtime behavior**, not developer tasks.
These are correct as written and are not touched by this proposal:

- System Settings deep-links for TCC permission remediation (FR6, FR60, UX-DR52, Story 5.1)
- Keychain Access as the API-key reveal path (ux-design-specification.md line 1616, Story 9.x)
- Manual frontmatter edits in Obsidian (FR26, DP4 — auricle never re-edits a vault note)

The distinction that matters: **a user choosing a GUI is a feature; a developer being forced into one is
a defect.**

---

## 2. Impact Analysis

### Epic impact

| Epic | Impact | Detail |
|---|---|---|
| Epic 1 | **Story 1.1 rewrite; Story 1.8 amendment** | Tasks 6–8 and AC2/AC3 restated declaratively; `ci.yml` gains a generate step and a drift check |
| Epic 2–8 | **None** | Pure SwiftPM library code; no project-configuration tasks |
| Epic 9 | **Stories 9.3, 9.4 amendment** | Cert creation becomes a script; signing identity moves to `.xcconfig`; release script regenerates the project |
| Epic 10 | **None** | Sparkle integration (Story 10.7) is an SPM dependency, declared in `Package.swift` |

Epic scope, count, sequencing, and priority are **unchanged**. No epic is added, removed, or redefined.
Stories 1.2 through 1.7 are untouched — all are SwiftPM library code that never needed Xcode.

### Artifact conflicts

- **PRD — no conflict.** The PRD does not specify project tooling. Two NFRs are touched and both improve:
  NFR-M7 (reproducible builds) is *strengthened* — a generated project derived from a checked-in manifest
  is more reproducible than a hand-configured one. NFR-C4 (total fixed cost $0) **holds only under a
  constraint**: Tuist's open-source CLI is free, and the hosted Tuist cache/server tier must not be adopted.
  That constraint is written into the new AR-INIT-6 below.
- **Architecture — conflicts at six sections.** §Selected Approach rationale, §Initialization,
  §Repository Layout, §Distribution Model → Implementation, §Per-build signing, §Development Workflow
  Integration. All six edits are in §4.
- **UX design specification — no conflict.** Every GUI reference in this document is end-user runtime
  behavior. No edits.
- **Secondary artifacts** — `.gitignore` (the generated project must be excluded), `ci.yml` (Story 1.8),
  `scripts/` (Epic 9 gains one script, Story 9.4's release script gains one step).

### Technical impact

`App/Auricle.xcodeproj` changes category: from a committed source artifact to a generated build artifact.
Consequences:

- A fresh clone has no `.xcodeproj` until `tuist generate` runs. Contributor docs and CI must say so.
- `project.pbxproj` diffs disappear from PRs. Project changes become diffs in `Project.swift` (Swift) and
  `config/*.xcconfig` (plain text) — both reviewable, neither machine-generated.
- The build gains a toolchain dependency (Tuist) that must be version-pinned for NFR-M7 to hold.

---

## 3. Recommended Approach

### Selected path: Direct Adjustment (Option 1)

Modify the existing stories within the current epic structure. No rollback (nothing is implemented).
No MVP review (no scope change).

**Effort: Low** — planning-document edits only; zero code rework, because zero code exists.
**Risk: Low-Medium** — the one genuine unknown is flagged and gated below.
**Timeline impact: None** — Story 1.1's task count is unchanged; the work shifts from GUI clicks to
writing two manifest files.

### Rationale

Doing this now costs a few hours of document edits. Deferring it costs: the first story stalls on a manual
step; every subsequent `xcodebuild` in CI depends on an artifact no agent can regenerate; and the
correction gets more expensive with every story that lands on top of the committed project file.

### Why Tuist + `.xcconfig`, and what was rejected

Apple recommends none of this. There is no `xcodebuild create-project` verb, Apple has never endorsed a
project generator, and SwiftPM still cannot emit a `.app` bundle in 2026. The officially documented path
is the GUI. Every CLI option here is third-party or hand-rolled, and the choice is between them.

- **Tuist (selected).** Swift manifests, type-checked, in the same language as the project. Most actively
  maintained of the generators; ships preinstalled on Xcode 26 CI stacks; tracked Xcode 16's buildable
  folders within one release cycle. It is the tool 2026 agent-assisted Xcode workflows converge on.
- **XcodeGen (rejected, retained as fallback).** Already installed here (2.46.0) and simpler — YAML, and
  this project's generator only has to produce two thin executable shells. Rejected on maintenance
  velocity: it is community-driven and slower-moving, which is the risk that bites across a 90-story
  project. It remains the designated fallback (see gate below), and the fallback is cheap precisely
  because settings live in xcconfigs, not in the manifest.
- **Pure SwiftPM + bundle assembly script (rejected).** Zero third-party dependency and a natural fit for
  AR-DIST-3's two-binary layout. Rejected because it places TCC permission stability — auricle's most
  fragile requirement (NFR-S2: grants key on a correctly-structured, correctly-signed bundle with a stable
  bundle ID) — on hand-rolled shell scripts, and overturns the "Xcode is the build-and-ship surface"
  rationale that Epic 9's `xcodebuild archive` flow depends on.

### The part that actually future-proofs this

**Every build setting goes in `.xcconfig`, not in the Tuist manifest.** `.xcconfig` is Apple's own
plain-text settings format, read natively by Xcode and `xcodebuild`, and CLI-editable. The generator is
then responsible only for target and file *structure*, while the settings that carry the load — hardened
runtime, sandbox off, arm64-only, deployment target, bundle ID, entitlements path — live in Apple-native
files that survive any generator change.

The escape hatch is explicit: if Tuist is ever abandoned, run `tuist generate` once, commit the result,
delete the manifest. The xcconfigs keep working untouched.

### Risk gate (unvalidated assumption)

The Tuist manifest API is confirmed against Tuist's `ProjectDescription` sources — `Product.app`,
`Product.commandLineTool`, `Package.local(path:)`, `TargetDependency.package(product:)`,
`InfoPlist.file(path:)`, `Entitlements.file(path:)`, and `Configuration.debug(name:settings:xcconfig:)`
all exist as this proposal uses them.

**What is not confirmed** is this specific arrangement: an Xcode project in `App/` consuming a local
SwiftPM package at the repository *root* via `.local(path: "..")`. That has not been empirically verified.

**Mitigation — Story 1.1 gains a new Task 0, a 30-minute spike that must pass before Task 1 begins:**
generate a throwaway project with one app target consuming one product from the root package, and confirm
`xcodebuild build` succeeds. If it fails, fall back to XcodeGen with an identical `.xcconfig` split — a
manifest-language swap only, because no build settings live in the manifest.

---

## 4. Detailed Change Proposals

### 4.1 New architectural commitments

**ADD to epics.md §Additional Requirements → Project Initialization & Starter Template (after AR-INIT-5):**

> - **AR-INIT-6:** Developer toolchain is declared and version-pinned in `mise.toml` (Tuist, SwiftFormat,
>   SwiftLint). `mise install` reproduces the exact toolchain on a fresh Mac and in CI; version drift
>   would break NFR-M7's byte-identical-rebuild guarantee. Tuist is used as the open-source CLI only —
>   the hosted Tuist cache/server tier is NOT adopted (NFR-C4: total fixed cost $0).

**ADD to epics.md §Additional Requirements → Architectural Patterns (after AR-PAT-10):**

> - **AR-PAT-11:** No GUI-required development tasks. Every step that produces, configures, signs, or
>   releases a build must be executable from a non-interactive shell. Xcode, Keychain Access, and System
>   Settings may be *used* by preference — they must never be *required*. A plan step whose only
>   documented path is a GUI navigation sequence is a planning defect. Enforcement: CI runs the full
>   build-and-sign path headlessly; a step CI cannot run is a step that does not exist. This governs
>   developer tasks only — end-user GUI affordances (System Settings permission remediation per FR6/FR60,
>   Keychain Access as the API-key reveal path, manual frontmatter edits in Obsidian per FR26) are
>   product behavior and are unaffected.

### 4.2 architecture.md — §Selected Approach

**Heading (line 168):**

```
OLD:  ### Selected Approach: Hybrid SwiftPM Library + Xcode App Project
NEW:  ### Selected Approach: Hybrid SwiftPM Library + Tuist-Generated Xcode App Project
```

**Rationale bullet (line 176):**

```
OLD:  - **First-timer-friendly: most module work happens in SwiftPM library targets, edited as plain
        Swift files in any editor or in Xcode.** Only the executable shell, signing, and bundling require
        Xcode-GUI work — that's a one-time setup, not a recurring per-module cost.

NEW:  - **First-timer-friendly: most module work happens in SwiftPM library targets, edited as plain
        Swift files in any editor or in Xcode.** The executable shell, signing, and bundling are declared
        in `Project.swift` and `config/*.xcconfig` and produced by `tuist generate` — no step in the build
        requires Xcode's GUI (AR-PAT-11).
```

**ADD a rationale bullet after line 176:**

> - **The Xcode project is a build artifact, not a source artifact.** `Project.swift` (Tuist manifest,
>   Swift) declares the two executable targets and their dependency on the root SwiftPM package;
>   `config/*.xcconfig` (Apple's own plain-text settings format) declares every build setting.
>   `App/Auricle.xcodeproj` is generated by `tuist generate` and is gitignored. Keeping settings in
>   xcconfigs rather than the manifest means the generator owns only structure: if Tuist is ever
>   abandoned, generate once, commit the result, and the xcconfigs continue to work unmodified.

**Rationale for the change:** the selected approach is unchanged in substance — SwiftPM for module
boundaries, Xcode for bundling and signing. Only the *authoring surface* for the Xcode half moves from
GUI to manifest.

### 4.3 architecture.md — §Initialization (lines 197–206)

```
OLD:  # Then in Xcode:
      #   File > New > Project > macOS > App > "Auricle" (SwiftUI, Swift)
      #   Add the SwiftPM root as a local package dependency
      #   Add a second target: Command Line Tool > "auricle-cli"
      #   Configure: Hardened Runtime ON, Sandbox OFF, code signing identity,
      #              Info.plist (LSUIElement=NO, microphone & screen-recording usage descriptions),
      #              entitlements (com.apple.security.device.audio-input, notifications)

NEW:  # Pin the toolchain (Tuist, SwiftFormat, SwiftLint) — AR-INIT-6
      mise install

      # Author the Xcode half as plain text — no GUI:
      #   Project.swift              Tuist manifest: AuricleApp (.app) + auricle-cli (.commandLineTool),
      #                              both depending on the root package via .package(product:)
      #   config/Shared.xcconfig     ENABLE_HARDENED_RUNTIME=YES, MACOSX_DEPLOYMENT_TARGET=14.0,
      #                              ARCHS=arm64, PRODUCT_BUNDLE_IDENTIFIER=com.auricle.app,
      #                              CODE_SIGN_ENTITLEMENTS=App/Auricle/Auricle.entitlements
      #                              (App Sandbox is absent, not disabled — the key is never set)
      #   config/Debug.xcconfig      #include "Shared.xcconfig"; CODE_SIGN_IDENTITY = -
      #   config/Release.xcconfig    #include "Shared.xcconfig"; CODE_SIGN_IDENTITY = Auricle Code Signing
      #   App/Auricle/Info.plist     LSUIElement=NO, NS*UsageDescription strings, CFBundleURLTypes
      #   App/Auricle/Auricle.entitlements   com.apple.security.device.audio-input

      tuist generate --no-open        # produces App/Auricle.xcodeproj (gitignored)
      xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp build
```

### 4.4 architecture.md — §Repository Layout (lines ~1864–1889)

```
ADD:  ├── Project.swift                     # Tuist manifest — Xcode target truth
      ├── Tuist.swift                       # Tuist project options
      ├── mise.toml                         # pinned toolchain (AR-INIT-6)
      ├── config/
      │   ├── Shared.xcconfig               # build settings — Apple-native, generator-independent
      │   ├── Debug.xcconfig
      │   └── Release.xcconfig

ANNOTATE:
      ├── App/
      │   ├── Auricle.xcodeproj/            # GENERATED by `tuist generate` — gitignored, never committed
      │   ├── Auricle/                      # SwiftUI app shell + Info.plist + entitlements (committed)
      │   └── auricle-cli/                  # CLI executable sources (committed)

FIX (pre-existing defect, unrelated to this change but in the same block):
      the diagram shows `Sources/auricle-cli/`, which contradicts AR-INIT-5's `App/auricle-cli/`.
      Story 1.1's Dev Notes already flag this ("AR-INIT-5 wins"). Correct the diagram.
```

### 4.5 architecture.md — §Distribution Model → Implementation (line 248)

```
OLD:  - Personal "Andrew Code Signing CA" certificate — root, self-signed, marked CA-capable (Basic
        Constraints: `CA: TRUE`). Generated via Keychain Access > Certificate Assistant > Create a
        Certificate (Identity Type: Self-Signed Root, Certificate Type: Code Signing) or via `openssl`.

NEW:  - Personal "Andrew Code Signing CA" certificate — root, self-signed, marked CA-capable (Basic
        Constraints: `CA: TRUE`). Generated by `scripts/create-signing-ca.sh` (idempotent) using `openssl`
        for key and certificate generation and `security import` to install into the login keychain, per
        AR-PAT-11. Keychain Access > Certificate Assistant produces an equivalent certificate but is not
        the documented path — a script is reviewable, repeatable, and runnable over SSH.
```

**Line 249:**

```
OLD:  - "Auricle Code Signing" leaf certificate — signed by the CA, used as the per-build signing identity
        in Xcode.
NEW:  - "Auricle Code Signing" leaf certificate — signed by the CA, named as `CODE_SIGN_IDENTITY` in
        `config/Release.xcconfig`.
```

### 4.6 architecture.md — §Per-build signing (lines 276–278)

```
OLD:  **Per-build signing (in Xcode):**

      - Project's Signing & Capabilities pane: Signing Identity = "Auricle Code Signing" (the leaf cert).
      - Hardened Runtime: enabled.
      - Sandbox: disabled (per PRD §Implementation Considerations).

NEW:  **Per-build signing (`config/Release.xcconfig`):**

      - `CODE_SIGN_IDENTITY = Auricle Code Signing` (the leaf cert), `CODE_SIGN_STYLE = Manual`.
      - `ENABLE_HARDENED_RUNTIME = YES`.
      - App Sandbox: the `com.apple.security.app-sandbox` entitlement is never set (per PRD
        §Implementation Considerations). Absent, not present-and-false.
```

### 4.7 architecture.md — §Development Workflow Integration (line ~2824)

```
OLD:  `xcodebuild -project App/Auricle.xcodeproj -scheme Auricle build` builds the GUI; `-scheme
      auricle-cli` builds the CLI. From Xcode's UI, both schemes are runnable from the scheme picker.

NEW:  A fresh clone has no `App/Auricle.xcodeproj` — it is generated. Run `mise install` once, then
      `tuist generate` to produce it. Thereafter `xcodebuild -project App/Auricle.xcodeproj -scheme
      AuricleApp build` builds the GUI and `-scheme auricle-cli` builds the CLI; both schemes are also
      runnable from Xcode's scheme picker. Re-run `tuist generate` after any change to `Project.swift`.
      Changes to `config/*.xcconfig` take effect without regenerating.
```

### 4.8 epics.md — AR-INIT-1 (line 234)

```
OLD:  - **AR-INIT-1:** Hybrid SwiftPM library + Xcode app project structure. Library targets in `Sources/`
        declared in `Package.swift`; Xcode project at `App/Auricle.xcodeproj` produces both the GUI binary
        (`AuricleApp`) and the CLI binary (`auricle-cli`); both depend on the SwiftPM library. SwiftPM
        target boundaries enforce SOLID at build-system level (cross-target imports rejected).

NEW:  - **AR-INIT-1:** Hybrid SwiftPM library + Tuist-generated Xcode app project structure. Library
        targets in `Sources/` declared in `Package.swift`. The Xcode project at `App/Auricle.xcodeproj` is
        GENERATED from `Project.swift` by `tuist generate` and is gitignored, never committed; it produces
        both the GUI binary (`AuricleApp`, product `.app`) and the CLI binary (`auricle-cli`, product
        `.commandLineTool`), each depending on the root SwiftPM package declared as `.local(path: "..")`
        and linked per-product via `.package(product:)`. SwiftPM target boundaries enforce SOLID at
        build-system level (cross-target imports rejected).
```

### 4.9 epics.md — AR-INIT-3 (line 236)

```
OLD:  - **AR-INIT-3:** Xcode project configuration: Hardened Runtime ON, App Sandbox OFF, Info.plist with
        `LSUIElement=NO` plus NS*UsageDescription strings (per Decision 4.4), entitlements
        (`com.apple.security.device.audio-input`, notifications), CFBundleURLTypes for `auricle://` scheme.

NEW:  - **AR-INIT-3:** Build configuration lives in plain-text files, never in the Xcode GUI (AR-PAT-11).
        `config/Shared.xcconfig` carries `ENABLE_HARDENED_RUNTIME=YES`, `MACOSX_DEPLOYMENT_TARGET=14.0`,
        `ARCHS=arm64`, `PRODUCT_BUNDLE_IDENTIFIER=com.auricle.app`, `CODE_SIGN_ENTITLEMENTS`; the App
        Sandbox key is absent entirely. `App/Auricle/Info.plist` (committed, hand-edited) carries
        `LSUIElement=NO`, the NS*UsageDescription strings (per Decision 4.4), and CFBundleURLTypes for the
        `auricle://` scheme. `App/Auricle/Auricle.entitlements` (committed) carries
        `com.apple.security.device.audio-input`. `Project.swift` references these by path —
        `infoPlist: .file(path:)`, `entitlements: .file(path:)`, and
        `settings: .settings(configurations: [.debug(name:xcconfig:), .release(name:xcconfig:)],
        defaultSettings: .none)` so the xcconfigs are authoritative and Tuist injects nothing.
```

### 4.10 epics.md — AR-INIT-4 (line 237)

```
OLD:  - **AR-INIT-4:** CI (`.github/workflows/ci.yml`) runs `swift build`, `swift test`, `xcodebuild build`
        for both schemes, `swiftformat --lint`, `swiftlint`. Release workflow (`release.yml`) runs
        `xcodebuild archive` + `codesign` + (v1.1) Sparkle appcast generation.

NEW:  - **AR-INIT-4:** CI (`.github/workflows/ci.yml`) runs `mise install`, `swift build`, `swift test`,
        `tuist generate --no-open`, `xcodebuild build` for both schemes, `swiftformat --lint`, `swiftlint`.
        CI additionally asserts `App/Auricle.xcodeproj` is NOT tracked by git (`git ls-files --error-unmatch`
        must fail) — a committed generated project is a regression of AR-INIT-1. Release workflow
        (`release.yml`) runs `mise install` + `tuist generate` + `xcodebuild archive` + `codesign` +
        (v1.1) Sparkle appcast generation.
```

### 4.11 epics.md — Story 1.8, `ci.yml` acceptance criteria (line ~1096)

```
OLD:  **Then** the workflow runs `swift build` (verify SwiftPM library compiles), `swift test` (…),
        `xcodebuild -project App/Auricle.xcodeproj -scheme AuricleApp build` and `-scheme auricle-cli
        build` (verify executables compile), `swiftformat --lint` and `swiftlint` (…)

NEW:  **Then** the workflow runs `mise install` (pinned toolchain per AR-INIT-6), `swift build`,
        `swift test` (…), `tuist generate --no-open`, `xcodebuild -project App/Auricle.xcodeproj -scheme
        AuricleApp build` and `-scheme auricle-cli build` (verify executables compile), `swiftformat
        --lint` and `swiftlint` (…)
        **And** the workflow fails if `App/Auricle.xcodeproj` is tracked by git (per AR-INIT-4)
        **And** the workflow fails if `tuist generate` produces a non-empty `git status` outside the
        gitignored project — the manifest and the working tree must agree
```

### 4.12 epics.md — Story 9.3, certificate creation (line ~3618)

```
OLD:  **Then** the artifacts exist: "Andrew Code Signing CA" certificate (root, self-signed, marked
        CA-capable, generated via Keychain Access > Certificate Assistant or `openssl`); "Auricle Code
        Signing" leaf certificate (signed by the CA, used as Xcode signing identity)

NEW:  **Then** `scripts/create-signing-ca.sh` (idempotent, per AR-PAT-11) generates both artifacts with no
        GUI step: "Andrew Code Signing CA" (root, self-signed, `basicConstraints=critical,CA:TRUE`,
        `keyUsage=critical,keyCertSign`, via `openssl req -x509`) and the "Auricle Code Signing" leaf
        (`openssl x509 -req` signed by the CA, `extendedKeyUsage=codeSigning`), each imported to the login
        keychain via `security import`
        **And** the script is re-runnable: a second invocation detects the existing identity via
        `security find-identity -v -p codesigning` and exits 0 without creating a duplicate
        **And** the leaf is named as `CODE_SIGN_IDENTITY` in `config/Release.xcconfig`, not selected in a
        signing pane
```

### 4.13 epics.md — Story 9.3, signing configuration (line ~3628)

```
OLD:  **Given** Xcode Signing & Capabilities
      **When** I configure the project per AR-DIST-3
      **Then** Signing Identity = "Auricle Code Signing" (the leaf cert); Hardened Runtime = enabled;
        Sandbox = disabled

NEW:  **Given** `config/Release.xcconfig`
      **When** I inspect it per AR-DIST-3 + AR-INIT-3
      **Then** `CODE_SIGN_IDENTITY = Auricle Code Signing`, `CODE_SIGN_STYLE = Manual`,
        `ENABLE_HARDENED_RUNTIME = YES`, and no `com.apple.security.app-sandbox` key appears in
        `App/Auricle/Auricle.entitlements`
      **And** `codesign -dv --entitlements - <bundle>` on the built product confirms all three, so the
        assertion is against the signed artifact rather than against project settings
```

### 4.14 epics.md — Story 9.4, release script (line ~3650)

```
OLD:  **Then** the script runs: `xcodebuild archive` for the GUI scheme; `codesign` with the leaf cert
        chained to "Andrew Code Signing CA" (per AR-DIST-3); package as `.dmg` (…)

NEW:  **Then** the script runs: `mise install`; `tuist generate --no-open` (the project is generated, not
        committed, per AR-INIT-1); `xcodebuild archive` for the GUI scheme; `codesign` with the leaf cert
        chained to "Andrew Code Signing CA" (per AR-DIST-3); package as `.dmg` (…)
```

Note on NFR-M7 (byte-identical rebuilds): the reproducibility assertion now spans one more input. The
pinned Tuist version in `mise.toml` is part of the reproducibility contract, alongside git SHA and Xcode
version. Story 9.4's existing NFR-M7 acceptance criterion should name it.

### 4.15 Story 1.1 — task rewrite

**Filename and title unchanged.** The slug
`1-1-project-initialization-xcode-swiftpm-hybrid` stays, and so does the title "Project Initialization
(Xcode + SwiftPM Hybrid)" — the structure is still a hybrid, only the authoring surface changed. Keeping
the slug avoids churning `sprint-status.yaml` keys for no semantic gain.

**ADD Task 0 (new, blocking — the risk gate from §3):**

> - [ ] **Task 0: Tuist local-package spike** (gates all later tasks)
>   - [ ] `mise install` (or `brew install tuist` if `mise.toml` is not yet written)
>   - [ ] In a scratch directory, create a minimal `Package.swift` with one library target and a minimal
>         `App/Project.swift` declaring one `.app` target with `packages: [.local(path: "..")]` and
>         `dependencies: [.package(product: "TheLibrary")]`
>   - [ ] `tuist generate --no-open && xcodebuild -scheme <app> build` — must exit 0
>   - [ ] **If this fails:** stop and fall back to XcodeGen (already installed, 2.46.0) with an identical
>         `config/*.xcconfig` split. Only the manifest language changes; no build setting moves. Record
>         the failure in the Dev Agent Record and note the deviation from AR-INIT-1.
>   - [ ] Delete the scratch directory. Do not commit it.

**REPLACE Task 6** (was: "Use Xcode GUI: File > New > Project…"):

> - [ ] **Task 6: Write `Project.swift` and `Tuist.swift`** (AC: #2, #3)
>   - [ ] `Tuist.swift` at repo root: `let tuist = Tuist(project: .tuist(generationOptions: .options()))`
>   - [ ] `Project.swift` at repo root: `packages: [.local(path: ".")]` (the root SwiftPM package)
>   - [ ] Declare target `AuricleApp`: `destinations: [.mac]`, `product: .app`,
>         `bundleId: "com.auricle.app"`, `deploymentTargets: .macOS("14.0")`,
>         `infoPlist: .file(path: "App/Auricle/Info.plist")`,
>         `entitlements: .file(path: "App/Auricle/Auricle.entitlements")`,
>         `sources: ["App/Auricle/**"]`, dependencies `.package(product:)` per the Composition Root
>         Dependency List in Dev Notes
>   - [ ] Declare target `auricle-cli`: `product: .commandLineTool`, `sources: ["App/auricle-cli/**"]`,
>         dependencies `.package(product:)` for every library product plus swift-argument-parser
>   - [ ] Project-level `settings:` → `.settings(configurations: [.debug(name: .debug, xcconfig:
>         "config/Debug.xcconfig"), .release(name: .release, xcconfig: "config/Release.xcconfig")],
>         defaultSettings: .none)`. `defaultSettings: .none` is load-bearing — it stops Tuist injecting
>         settings that would silently shadow the xcconfigs.
>   - [ ] Run `tuist generate --no-open`; confirm `App/Auricle.xcodeproj` appears
>   - [ ] Confirm `App/Auricle.xcodeproj` is gitignored: `git status --porcelain` shows nothing under `App/`
>         except the committed source directories

**REPLACE Task 7** (was: "In Xcode: … Build Settings > Architectures"):

> - [ ] **Task 7: Write `config/*.xcconfig` and `App/Auricle/Info.plist`** (AC: #2, #3)
>   - [ ] `config/Shared.xcconfig`: `MACOSX_DEPLOYMENT_TARGET = 14.0`; `ARCHS = arm64`;
>         `EXCLUDED_ARCHS = x86_64`; `ENABLE_HARDENED_RUNTIME = YES`;
>         `PRODUCT_BUNDLE_IDENTIFIER = com.auricle.app`;
>         `CODE_SIGN_ENTITLEMENTS = App/Auricle/Auricle.entitlements`;
>         `SWIFT_VERSION = 5.10`. Do NOT add `ENABLE_APP_SANDBOX` in any form — absent, not `NO`.
>   - [ ] `config/Debug.xcconfig`: `#include "Shared.xcconfig"`; `CODE_SIGN_IDENTITY = -` (ad-hoc)
>   - [ ] `config/Release.xcconfig`: `#include "Shared.xcconfig"`;
>         `CODE_SIGN_IDENTITY = Auricle Code Signing`; `CODE_SIGN_STYLE = Manual`.
>         Until Story 9.3 creates that identity, this configuration will not sign — that is expected and
>         is Epic 9's problem, not this story's.
>   - [ ] `App/Auricle/Info.plist` (hand-written XML, committed): `LSUIElement = NO`; the three
>         NS*UsageDescription strings **verbatim** per UX-DR44 (text unchanged from the original Task 7 —
>         do not paraphrase); `CFBundleURLTypes` with `CFBundleURLName = com.auricle.app.url` and
>         `CFBundleURLSchemes = ["auricle"]`
>   - [ ] Verify with `plutil -lint App/Auricle/Info.plist`

**REPLACE Task 8** (was: "In Xcode: Signing & Capabilities > + Capability > add Microphone"):

> - [ ] **Task 8: Write `App/Auricle/Auricle.entitlements`** (AC: #2)
>   - [ ] Hand-written plist, committed, containing `com.apple.security.device.audio-input` = `true`
>   - [ ] Confirm `com.apple.security.app-sandbox` does NOT appear (would break ScreenCaptureKit and vault
>         writes)
>   - [ ] `UNUserNotificationCenter` requires no entitlement key on macOS — authorization is requested at
>         runtime and gated by `NSUserNotificationsUsageDescription`. Record this as a comment in
>         `AuricleApp.swift` (this resolves the open question left in the original Task 8)
>   - [ ] Verify with `plutil -lint App/Auricle/Auricle.entitlements`

**AMEND Task 10 (`.gitignore`):**

> - [ ] ADD `App/Auricle.xcodeproj/` — generated by `tuist generate`, never committed (AR-INIT-1)
> - [ ] ADD `*.xcworkspace/` (except any committed shared scheme data, if introduced later)
> - [ ] ADD `.tuist/` and `Derived/` (Tuist local cache and derived artifacts)

**AMEND Task 11 (verification):**

> - [ ] Insert `tuist generate --no-open` before both `xcodebuild` invocations
> - [ ] ADD: `rm -rf App/Auricle.xcodeproj && tuist generate --no-open && xcodebuild … build` — proves the
>       project is reproducible from the manifest alone, which is the whole point of AR-INIT-1
> - [ ] The existing cross-target-import rejection check (temporary `import Transcribe` in `Sources/Capture/`)
>       is unchanged — it tests `Package.swift`, which this correction does not touch

**REPLACE Dev Notes paragraph (line 363):**

```
OLD:  **One detail-but-load-bearing point:** The `App/Auricle.xcodeproj` is created via Xcode's GUI
        (because Xcode's project format is XML and hand-rolling it is fragile). Once created, the
        `.xcodeproj` is committed to git. Subsequent edits to project settings happen in Xcode and produce
        a diff in `App/Auricle.xcodeproj/project.pbxproj` — that diff is human-reviewable in PRs.

NEW:  **One detail-but-load-bearing point:** `App/Auricle.xcodeproj` is a build artifact. It is generated
        by `tuist generate` from `Project.swift` and is gitignored — hand-rolling `project.pbxproj` is
        fragile, and so is hand-editing it afterwards. Project changes are made by editing `Project.swift`
        (structure) or `config/*.xcconfig` (settings) and regenerating; both produce reviewable plain-text
        diffs in PRs. If you open the project in Xcode and change a setting through the UI, your change is
        destroyed on the next `tuist generate` — make the change in the xcconfig instead.
```

**AMEND the AR-commitment mapping table (line ~353):**

```
OLD:  | AR-INIT-3 | Xcode project: Hardened Runtime ON, Sandbox OFF, Info.plist + entitlements + URL
        scheme | Xcode project Build Settings + Info.plist + entitlements file |

NEW:  | AR-INIT-3 | Build config in plain text: xcconfigs + Info.plist + entitlements + URL scheme |
        `config/*.xcconfig`, `plutil -lint`, `codesign -dv --entitlements -` |
      | AR-INIT-6 | Toolchain pinned in `mise.toml` | `mise install` succeeds on a clean checkout |
      | AR-PAT-11 | No GUI-required steps in this story | Every task is a shell command or a file write |
```

### 4.16 `.gitignore` — folded into Story 1.1 Task 10, not applied standalone

The repository's current `.gitignore` is a generic Python/Cursor/Marimo template with no Swift or Xcode
section; Story 1.1 Task 10 is what creates that section. Adding these three lines now would leave the file
half-configured, and Task 10 rewrites the same region. The entries are therefore specified in Task 10:

```
App/Auricle.xcodeproj/     # generated — regenerate with `tuist generate` (AR-INIT-1)
.tuist/
Derived/
```

---

## 5. Implementation Handoff

### Scope classification: Moderate

Not Minor: this amends four approved architectural commitments (AR-INIT-1, AR-INIT-3, AR-INIT-4) and adds
two (AR-INIT-6, AR-PAT-11), which is architect-level authority rather than a dev-agent edit.

Not Major: no epic is added, removed, resequenced, or rescoped; no PRD requirement changes; no MVP scope
moves; no work is rolled back. The change is confined to *how* the Xcode half of the build is authored.

### Handoff

| Recipient | Responsibility |
|---|---|
| **Architect** | Apply §4.1–§4.7 to `architecture.md` and §4.8–§4.10 to the AR-INIT block in `epics.md`. Owns AR-INIT-6 and AR-PAT-11 wording. |
| **PO / SM** | Apply §4.11–§4.14 to Stories 1.8, 9.3, 9.4 in `epics.md`. Bump `last_updated` in `sprint-status.yaml`. |
| **Dev (Story 1.1)** | Apply §4.15 to the story file, then implement. Task 0 is the gate — do not start Task 1 until it passes. |

### Success criteria

1. `git grep -niE 'File > New|Signing & Capabilities|Build Settings >|Keychain Access > Certificate'`
   returns no hits in `_bmad-output/` outside this proposal and outside end-user UX copy.
2. A clean clone reaches a built `.app` with only: `mise install && tuist generate && xcodebuild build`.
3. `App/Auricle.xcodeproj` is absent from `git ls-files`.
4. Story 1.1 has no task that requires a display.

### `sprint-status.yaml` impact

No epic added, removed, or renumbered. No story added or removed. Story 1.1 keeps its slug and its
`ready-for-dev` status. Only `last_updated` changes — from `2026-05-02` to `2026-09-15`.
