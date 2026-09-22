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

import AVFoundation
import CoreGraphics
import Foundation
import os
import UserNotifications

/// Foundation spells the same write several ways; the rule has to match all
/// of them, so each one is exercised separately here.
func atomicWriterBypassFixture(data: Data, text: String, url: URL, path: String) throws {
    try data.write(to: url) // expect: atomic_writer_bypass
    try text.write(toFile: path, atomically: true, encoding: .utf8) // expect: atomic_writer_bypass
    (data as NSData).write(toFile: path, atomically: true) // expect: atomic_writer_bypass
    _ = FileManager.default.createFile(atPath: path, contents: nil) // expect: atomic_writer_bypass
    _ = FileManager().createFile(atPath: path, contents: nil) // expect: atomic_writer_bypass
}

/// Exercises both alternatives of the rule: the os.Logger(subsystem:category:)
/// bypass, which matters most because Log.swift itself is built on Logger, and
/// the legacy os_log( free function. Narrowing either alternative would leave
/// the other marked line firing, so each needs its own line.
func logFacadeBypassFixture() {
    let logger = Logger(subsystem: "com.auricle.app", category: "probe") // expect: log_facade_bypass
    logger.info("test")
    os_log("probe") // expect: log_facade_bypass
}

func printBypassFixture() {
    print("probe") // expect: print_bypass
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

/// Every OS entry point PermissionChecker.swift exists to wrap: two on
/// AVCaptureDevice, three on UNUserNotificationCenter (`.notificationSettings(`
/// and its completion-handler sibling `.getNotificationSettings(
/// completionHandler:`, plus `.requestAuthorization(options:`), two free Core
/// Graphics functions, and two on AVAudioApplication — macOS 14+'s newer
/// audio-permission API, already reachable through this file's own
/// `import AVFoundation`. Each needs its own line — this rule's regex is an
/// alternation, same self-check rationale as atomicWriterBypassFixture above.
func permissionCheckerBypassFixture(center: UNUserNotificationCenter) async throws {
    _ = AVCaptureDevice.authorizationStatus(for: .audio) // expect: permission_checker_bypass
    _ = await AVCaptureDevice.requestAccess(for: .audio) // expect: permission_checker_bypass
    _ = await center.notificationSettings() // expect: permission_checker_bypass
    _ = try await center.requestAuthorization(options: [.alert, .sound]) // expect: permission_checker_bypass
    _ = CGPreflightScreenCaptureAccess() // expect: permission_checker_bypass
    _ = CGRequestScreenCaptureAccess() // expect: permission_checker_bypass
    center.getNotificationSettings(completionHandler: { _ in }) // expect: permission_checker_bypass
    _ = AVAudioApplication.shared.recordPermission // expect: permission_checker_bypass
    _ = await AVAudioApplication.requestRecordPermission() // expect: permission_checker_bypass
}

/// `UnrelatedResourcePool` is not `AVCaptureDevice` — its own same-named
/// `requestAccess(for:)` proves the rule's `AVCaptureDevice\.` qualification
/// actually discriminates by receiver instead of matching the method name
/// bare, which would false-positive on any unrelated type that happens to
/// share it. No `// expect:` marker: this line must NOT produce a violation.
func permissionCheckerBypassNegativeFixture() {
    _ = UnrelatedResourcePool.requestAccess(for: "probe")
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

enum UnrelatedResourcePool {
    static func requestAccess(for _: String) -> Bool {
        true
    }
}
