// Deliberately violates every custom_rules entry in .swiftlint.yml.
// scripts/verify-custom-lint-rules.sh lints this file in isolation and
// asserts a violation fires on every line marked `// expect: <rule id>` —
// the regression check for a rule silently going blind (a typo'd regex, or
// a rule that stops matching the real call shape it was meant to catch, the
// way log_facade_bypass once did against os.Logger construction).
//
// A rule whose regex is a chain of alternatives needs one marked line per
// alternative. Asserting only that the rule id appears somewhere in the
// output cannot tell a rule that still catches every shape from one that
// has quietly lost all but one of them.
//
// Globally excluded in .swiftlint.yml so the normal repo-wide `swiftlint
// lint --strict .` pass never scores this file's intentional violations.
// The verification script defeats that exclusion by naming the path
// directly and *not* passing --force-exclude, which is the flag that would
// make swiftlint honor the exclusion for an explicitly-named file. Not part
// of any SwiftPM target: this is CI tooling, not application or test code.

import Foundation
import os

/// Foundation spells the same write several ways; the rule has to match all
/// of them, so each one is exercised separately here.
func atomicWriterBypassFixture(data: Data, text: String, url: URL, path: String) throws {
    try data.write(to: url) // expect: atomic_writer_bypass
    try text.write(toFile: path, atomically: true, encoding: .utf8) // expect: atomic_writer_bypass
    (data as NSData).write(toFile: path, atomically: true) // expect: atomic_writer_bypass
    _ = FileManager.default.createFile(atPath: path, contents: nil) // expect: atomic_writer_bypass
    _ = FileManager().createFile(atPath: path, contents: nil) // expect: atomic_writer_bypass
}

/// Exercises the os.Logger(subsystem:category:) bypass, not just the legacy
/// os_log( free function — Log.swift itself is built on Logger, so this is
/// the pattern that actually matters.
func logFacadeBypassFixture() {
    let logger = Logger(subsystem: "com.auricle.app", category: "probe") // expect: log_facade_bypass
    logger.info("test")
}

func transcriptDecodeBypassFixture() {
    _ = try? JSONDecoder().decode(TranscriptPayload.self, from: Data()) // expect: transcript_decode_bypass
}

func telemetrySQLBypassFixture() {
    let insertTelemetry = "INSERT INTO telemetry (meeting_id) VALUES ('x')" // expect: telemetry_sql_bypass
    let insertStageEvent = "INSERT INTO stage_events (meeting_id) VALUES ('x')" // expect: telemetry_sql_bypass
    _ = (insertTelemetry, insertStageEvent)
}

func compositionRootStrategyBypassFixture() {
    _ = ClaudeCitationsSummarizer() // expect: composition_root_strategy_bypass
    _ = WhisperKitStreamTranscriber() // expect: composition_root_strategy_bypass
    _ = GoogleCalendarSource() // expect: composition_root_strategy_bypass
}

func accessibilityLabelMissingFixture() {
    Button("Save") {} // expect: accessibility_label_missing
}

/// Synthetic stand-ins so this file compiles standalone, with no dependency
/// on Core/SwiftUI/the real vendor types those modules declare.
struct TranscriptPayload: Decodable {}
struct ClaudeCitationsSummarizer {}
struct WhisperKitStreamTranscriber {}
struct GoogleCalendarSource {}
struct Button {
    init(_: String, action _: () -> Void) {}
}
