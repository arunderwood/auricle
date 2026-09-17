// Deliberately violates every custom_rules entry in .swiftlint.yml, one
// violation per rule (Story 1.8). scripts/verify-custom-lint-rules.sh lints
// this file in isolation and asserts every expected rule id fires — the
// regression check for a rule silently going blind (a typo'd regex, or a
// rule that stops matching the real call shape it was meant to catch, the
// way log_facade_bypass once did against os.Logger construction).
//
// Globally excluded in .swiftlint.yml so the normal repo-wide `swiftlint
// lint --strict .` pass never scores this file's intentional violations —
// the verification script overrides that with --force-exclude. Not part of
// any SwiftPM target: this is CI tooling, not application or test code.
// Keep each fixture's call shape in sync with its rule's regex whenever
// either changes.

import Foundation
import os

func atomicWriterBypassFixture() {
    _ = FileManager.default.createFile(atPath: "x", contents: nil)
}

/// Exercises the os.Logger(subsystem:category:) bypass, not just the legacy
/// os_log( free function — Log.swift itself is built on Logger, so this is
/// the pattern that actually matters.
func logFacadeBypassFixture() {
    let logger = Logger(subsystem: "com.auricle.app", category: "probe")
    logger.info("test")
}

func transcriptDecodeBypassFixture() {
    _ = try? JSONDecoder().decode(TranscriptPayload.self, from: Data())
}

func telemetrySQLBypassFixture() {
    let sql = "INSERT INTO telemetry (meeting_id) VALUES ('x')"
    _ = sql
}

func compositionRootStrategyBypassFixture() {
    _ = ClaudeCitationsSummarizer()
}

func accessibilityLabelMissingFixture() {
    Button("Save") {}
}

/// Synthetic stand-ins so this file compiles standalone, with no dependency
/// on Core/SwiftUI/the real vendor types those modules declare.
struct TranscriptPayload: Decodable {}
struct ClaudeCitationsSummarizer {}
struct Button {
    init(_: String, action _: () -> Void) {}
}
