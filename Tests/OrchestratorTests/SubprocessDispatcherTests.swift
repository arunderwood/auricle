import ArgumentParser
import Core
import Foundation
@testable import Orchestrator
import Testing

/// A 26-character, Crockford-base32-safe (no `I`/`L`/`O`/`U`) stand-in ULID.
private func meetingIDString(_ tag: String) -> String {
    let prefix = "01" + tag
    return prefix + String(repeating: "9", count: 26 - prefix.count)
}

/// A stand-in `auricle-cli`: a shell script that exits with `exitCode`,
/// optionally waiting until `gate` exists first.
func makeStubExecutable(exitCode: Int32 = 0, waitingFor gate: URL? = nil) throws -> URL {
    let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("stub-auricle-cli-\(UUID().uuidString)")
    var script = "#!/bin/sh\n"
    if let gate {
        script += "while [ ! -e '\(gate.path)' ]; do sleep 0.01; done\n"
    }
    script += "exit \(exitCode)\n"
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
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

// MARK: - The argv the dispatcher builds, read by the worker's own parse type

/// `InternalStageArguments` is the type `InternalStageWorker` reads its command
/// line with, and the type `makeProcess` builds argv from, so this is the
/// dispatcher-to-worker contract: a renamed option or a reordered argument
/// fails here instead of making every worker die at argument parsing.
@Test(arguments: PipelineStage.allCases, [nil, "/vaults/notes with space"] as [String?])
func theArgvMakeProcessBuildsParsesBackToTheValuesPassedIn(stage: PipelineStage, vaultPath: String?) throws {
    let stubURL = URL(fileURLWithPath: "/tmp/stub-auricle-cli-does-not-need-to-exist")
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stubURL }, resolveVaultPath: { vaultPath })
    let id = try #require(MeetingID(ulid: meetingIDString("ARG1")))

    let process = try dispatcher.makeProcess(stage: stage, meetingID: id, workerProtocolVersion: WorkerProtocolVersion.current)
    let argv = try #require(process.arguments)

    #expect(argv.first == "__internal-stage")
    let parsed = try InternalStageArguments.parse(Array(argv.dropFirst()))
    #expect(parsed.stage == stage.rawValue)
    #expect(parsed.id == id.rawValue)
    #expect(parsed.workerProtocolVersion == WorkerProtocolVersion.current)
    #expect(parsed.vaultPath == vaultPath)
    #expect(parsed.decide() == .run(stage: stage, meetingID: id))
}

@Test func theArgumentsBuilderIsWhatMakeProcessUses() throws {
    let stubURL = URL(fileURLWithPath: "/tmp/stub-auricle-cli-does-not-need-to-exist")
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stubURL }, resolveVaultPath: { "/vault" })
    let id = try #require(MeetingID(ulid: meetingIDString("ARG2")))

    let process = try dispatcher.makeProcess(stage: .summarize, meetingID: id, workerProtocolVersion: 1)

    #expect(process.arguments == InternalStageArguments(stage: "summarize", id: id.rawValue, workerProtocolVersion: 1, vaultPath: "/vault").arguments)
}

@Test func aWorkerAtAnotherProtocolVersionMapsToTheStateErrorExitWithTheMismatchPayload() throws {
    let stubURL = URL(fileURLWithPath: "/tmp/stub-auricle-cli-does-not-need-to-exist")
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stubURL }, resolveVaultPath: { nil })
    let id = try #require(MeetingID(ulid: meetingIDString("ARG3")))
    let argv = try #require(try dispatcher.makeProcess(stage: .summarize, meetingID: id, workerProtocolVersion: 99).arguments)

    let parsed = try InternalStageArguments.parse(Array(argv.dropFirst()))

    guard case let .exit(status) = parsed.decide() else {
        Issue.record("expected an exit decision")
        return
    }
    #expect(status.code == WorkerExitCode.stateError)
    #expect(status.message == "{\"error\":\"worker_protocol_version_mismatch\",\"expected\":1,\"received\":99}")
}

@Test func anUnknownStageMapsToTheCallerErrorExit() throws {
    let arguments = try InternalStageArguments.parse(["frobnicate", meetingIDString("ARG4"), "--worker-protocol-version", "1"])

    #expect(arguments.decide() == .exit(WorkerExitStatus(code: WorkerExitCode.callerError, message: "__internal-stage: unrecognized stage 'frobnicate'.")))
}

@Test func aMalformedMeetingIDMapsToTheCallerErrorExitForEveryStage() {
    for stage in PipelineStage.allCases {
        let arguments = InternalStageArguments(stage: stage.rawValue, id: "not-a-ulid", workerProtocolVersion: 1)

        #expect(arguments.decide() == .exit(WorkerExitStatus(code: WorkerExitCode.callerError, message: "__internal-stage: 'not-a-ulid' is not a valid meeting ID.")))
    }
}

/// A caller that gets both wrong is told about the stage: the order is part of
/// the protocol.
@Test func theStageIsCheckedBeforeTheProtocolVersionAndTheVersionBeforeTheID() {
    let bothWrong = InternalStageArguments(stage: "frobnicate", id: "not-a-ulid", workerProtocolVersion: 99)
    guard case let .exit(first) = bothWrong.decide() else {
        Issue.record("expected an exit decision")
        return
    }
    #expect(first.code == WorkerExitCode.callerError)
    #expect(first.message?.contains("unrecognized stage") == true)

    let versionAndIDWrong = InternalStageArguments(stage: "summarize", id: "not-a-ulid", workerProtocolVersion: 99)
    guard case let .exit(second) = versionAndIDWrong.decide() else {
        Issue.record("expected an exit decision")
        return
    }
    #expect(second.code == WorkerExitCode.stateError)
}

@Test func aCommandLineThatDoesNotParseIsTheUsageExitCode() {
    do {
        _ = try InternalStageArguments.parse(["summarize"])
        Issue.record("expected a parse failure")
    } catch {
        #expect(InternalStageArguments.exitCode(for: error).rawValue == WorkerExitCode.usage)
    }
}

// MARK: - `onExit`

/// The stub exits at once, the case where the handler is most likely to be
/// late; repeated so every one of many quick exits is seen to be reported.
@Test func dispatchReportsAnImmediateExitThroughOnExit() async throws {
    let stub = try makeStubExecutable(exitCode: 3)
    defer { try? FileManager.default.removeItem(at: stub) }
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stub }, resolveVaultPath: { nil })
    let id = try #require(MeetingID(ulid: meetingIDString("EXT1")))
    let collector = WorkerExitCollector()

    for _ in 0 ..< 20 {
        try dispatcher.dispatch(stage: .summarize, meetingID: id, onExit: collector.add)
    }

    #expect(await waitUntil { collector.exits.count == 20 })
    #expect(collector.exits.allSatisfy { $0 == WorkerExit(stage: .summarize, meetingID: id, status: 3) })
}

@Test func dispatchWithoutOnExitLeavesTheTerminationHandlerUnset() throws {
    let stub = try makeStubExecutable()
    defer { try? FileManager.default.removeItem(at: stub) }
    let dispatcher = SubprocessDispatcher(resolveExecutablePath: { stub }, resolveVaultPath: { nil })
    let id = try #require(MeetingID(ulid: meetingIDString("EXT2")))

    let process = try dispatcher.dispatch(stage: .summarize, meetingID: id)
    process.waitUntilExit()

    #expect(process.terminationHandler == nil)
}
