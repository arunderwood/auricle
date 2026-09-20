import Core
import Foundation
import Orchestrator
import Pipeline
import Testing
import Transcribe

private func stubExecutable(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stub-worker-\(UUID().uuidString)")
    try AtomicWriter.write(Data("#!/bin/sh\n\(body)\n".utf8), to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func launcher(running executable: URL) -> SubprocessStageLauncher {
    SubprocessStageLauncher(dispatcher: SubprocessDispatcher(resolveExecutablePath: { executable }, resolveVaultPath: { nil }))
}

@Test(arguments: [Int32(0), 7, 75])
func theLauncherReturnsTheWorkersExitStatus(status: Int32) async throws {
    let executable = try stubExecutable("exit \(status)")
    defer { try? FileManager.default.removeItem(at: executable) }

    let result = try await launcher(running: executable).run(stage: .transcribe, meetingID: MeetingID.generate(), publishAnyway: false)

    #expect(result == .exited(status))
}

@Test func theLauncherPassesPublishAnywayOnTheArgumentVector() async throws {
    let executable = try stubExecutable("for arg in \"$@\"; do [ \"$arg\" = \"--publish-anyway\" ] && exit 9; done; exit 0")
    defer { try? FileManager.default.removeItem(at: executable) }
    let subject = launcher(running: executable)
    let id = MeetingID.generate()

    #expect(try await subject.run(stage: .summarize, meetingID: id, publishAnyway: true) == .exited(9))
    #expect(try await subject.run(stage: .summarize, meetingID: id, publishAnyway: false) == .exited(0))
}

@Test func cancellingTheCallerTerminatesTheWorkerAndThrows() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("started-\(UUID().uuidString)")
    let executable = try stubExecutable("touch '\(marker.path)'; sleep 60")
    defer {
        try? FileManager.default.removeItem(at: executable)
        try? FileManager.default.removeItem(at: marker)
    }
    let subject = launcher(running: executable)
    let task = Task { try await subject.run(stage: .summarize, meetingID: MeetingID.generate(), publishAnyway: false) }
    while !FileManager.default.fileExists(atPath: marker.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    let started = ContinuousClock.now

    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - started < .seconds(10))
}

@Test func theCLIDispatcherSpawnsTheRunningBinary() throws {
    let dispatcher = SubprocessDispatcher.forRunningCLI()

    let process = try dispatcher.makeProcess(stage: .summarize, meetingID: MeetingID.generate())

    let executable = try #require(process.executableURL)
    #expect(executable == Bundle.main.executableURL)
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
}

@Test func aWorkerKilledBySignalIsReportedAsSignaled() async throws {
    let executable = try stubExecutable("kill -KILL $$")
    defer { try? FileManager.default.removeItem(at: executable) }

    let result = try await launcher(running: executable).run(stage: .transcribe, meetingID: MeetingID.generate(), publishAnyway: false)

    #expect(result == .signaled(SIGKILL))
}
