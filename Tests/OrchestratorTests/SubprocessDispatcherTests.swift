import Core
import Foundation
@testable import Orchestrator
import Testing

/// A 26-character, Crockford-base32-safe (no `I`/`L`/`O`/`U`) stand-in ULID.
private func meetingIDString(_ tag: String) -> String {
    let prefix = "01" + tag
    return prefix + String(repeating: "9", count: 26 - prefix.count)
}

@Test func makeProcessSetsExecutablePathAndInternalStageArgumentVector() throws {
    let stubURL = URL(fileURLWithPath: "/tmp/stub-auricle-cli-does-not-need-to-exist")
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stubURL }, resolveVaultPath: { nil })
    let id = try #require(MeetingID(ulid: meetingIDString("DSP1")))

    let process = try dispatcher.makeProcess(stage: .reviewDiarization, meetingID: id, workerProtocolVersion: 1)

    #expect(process.executableURL == stubURL)
    #expect(process.arguments == [
        "__internal-stage", "review-diarization", id.rawValue, "--worker-protocol-version", "1",
    ])
}

@Test func makeProcessAppendsVaultPathWhenTheResolverSuppliesOne() throws {
    let stubURL = URL(fileURLWithPath: "/tmp/stub-auricle-cli-does-not-need-to-exist")
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stubURL }, resolveVaultPath: { "/vaults/notes with space" })
    let id = try #require(MeetingID(ulid: meetingIDString("DSP4")))

    let process = try dispatcher.makeProcess(stage: .summarize, meetingID: id, workerProtocolVersion: 1)

    #expect(process.arguments == [
        "__internal-stage", "summarize", id.rawValue,
        "--worker-protocol-version", "1",
        "--vault-path", "/vaults/notes with space",
    ])
}

@Test func makeProcessOmitsVaultPathWhenTheResolverSuppliesNone() throws {
    let stubURL = URL(fileURLWithPath: "/tmp/stub-auricle-cli-does-not-need-to-exist")
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stubURL }, resolveVaultPath: { nil })
    let id = try #require(MeetingID(ulid: meetingIDString("DSP5")))

    let process = try dispatcher.makeProcess(stage: .summarize, meetingID: id, workerProtocolVersion: 1)

    #expect(process.arguments?.contains("--vault-path") == false)
}

@Test func makeProcessThrowsWhenExecutablePathResolverReturnsNil() throws {
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { nil }, resolveVaultPath: { nil })
    let id = try #require(MeetingID(ulid: meetingIDString("DSP2")))

    #expect(throws: SubprocessDispatcher.DispatchError.executableNotFound) {
        try dispatcher.makeProcess(stage: .transcribe, meetingID: id)
    }
}

/// Exercises `dispatch` end to end against a real (stub) executable — the
/// only way to confirm the constructed `Process` is actually launchable, not
/// just shaped correctly. The stub stands in for `auricle-cli`, which
/// doesn't exist until Story 1.7.
@Test func dispatchLaunchesTheResolvedExecutableAndReturnsARunningProcess() throws {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("stub-auricle-cli-\(UUID().uuidString)")
    try "#!/bin/sh\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { scriptURL }, resolveVaultPath: { nil })
    let id = try #require(MeetingID(ulid: meetingIDString("DSP3")))

    let process = try dispatcher.dispatch(stage: .summarize, meetingID: id)
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
}
