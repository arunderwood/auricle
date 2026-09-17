<!-- bmad:context -->
<!-- Verified 2026-09-16 against 1221202. Managed by bmad-project-context; edits inside this block are replaced on refresh. Keep anything you want preserved outside the markers. -->

## auricle

Local-first macOS meeting notetaker: capture → transcribe → diarize → attribute → summarize → persist to an Obsidian vault. Hybrid SwiftPM library (`Sources/`) + Tuist-generated Xcode app (`App/`), Swift 6.3, GRDB-backed SQLite state. Planning docs (PRD, architecture, epics) live in `_bmad-output/planning-artifacts/`; per-story implementation specs live in `_bmad-output/implementation-artifacts/`; engineering notes in `docs/`.

## Policy

- Branch names are semantic — describe the change, never opaque (`fix1`, `wip`, `tmp`) — as `type/short-kebab-description` (`feat/`, `fix/`, `docs/`) or Claude Code's auto-generated `claude/<slug>-<hash>`.

## Where things are

- `Sources/` — SwiftPM library modules, covered by `swift test`.
- `App/` — Tuist-managed Xcode project (`AuricleApp` GUI + `auricle-cli` CLI). `App/Auricle.xcodeproj` is gitignored, never committed; regenerate via `tuist generate` after any `Project.swift` change.
- Story completion status: each story's own `_bmad-output/implementation-artifacts/spec-<id>-*.md` frontmatter `status` — not `sprint-status.yaml` (see pitfalls).

## Running and verifying

- SwiftPM library: `swift build && swift test`.
- Xcode/CLI side, not covered by `swift test`: `cd App && tuist generate --no-open`, then `xcodebuild -project Auricle.xcodeproj -scheme auricle-cli build` (or `-scheme AuricleApp`).
- Toolchain is pinned: Xcode 26.4.1 (`.xcode-version`), Tuist/swiftformat/swiftlint via `mise.toml` — run `mise install` before first build.

## Conventions that differ from defaults

- Single-implementation primitives — `StateStore` (all state reads/writes), `StageEventLogger` (all `stage_events` writes), `TelemetryRecorder` (all `telemetry` writes), `Log` (all logging), `AtomicWriter` (all file writes), `MeetingIDResolver` (all `<id>` argument parsing) — bypassing one with an inline equivalent is a defect, not a style choice.
- JSON dialect is chosen by what the JSON is for, not applied globally: snake_case for cache artifacts/vault frontmatter/`stage_events.metadata_json`, camelCase for CLI `--json` output — declare `CodingKeys` explicitly per type, never rely on `.convertFromSnakeCase`.

## Known pitfalls

- New logic that lives only in `App/` has no automated test coverage — `Package.swift`'s test targets only cover `Sources/*`. Land real logic in a `Sources/` module and call it from a thin `App/` wrapper so it stays reachable by `swift test`.
- `sprint-status.yaml` is not updated by the story-implementation workflow — treat each story's own spec file frontmatter `status` as ground truth for what's actually done.
- A Tuist target name with a hyphen (e.g. `auricle-cli`) builds its product with underscores substituted unless `productName:` is set explicitly in `Project.swift` — by-name executable lookups (`Bundle.main.url(forAuxiliaryExecutable:)`) silently fail against the wrong name otherwise.

<!-- /bmad:context -->
