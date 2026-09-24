@testable import Capture
import Core
import Foundation
import Telemetry
import Testing

/// Every end `stage.endedCaptures` reports, collected as it arrives. The
/// stream has one consumer, so a test calls this once per stage.
private func collectEnds(of stage: CaptureStage) -> Box<[MeetingID]> {
    let ends = Box<[MeetingID]>([])
    let stream = stage.endedCaptures
    Task {
        for await meetingID in stream {
            ends.value.append(meetingID)
        }
    }
    return ends
}

/// What a session whose finalize failed leaves: samples on disk under the
/// placeholder header `WAVWriter.init` wrote.
private func writeUnfinalizedWAV(seconds: Int, fixture: StageFixture) throws {
    let writer = try WAVWriter(meetingID: fixture.id, cacheDirectory: { fixture.root.appendingPathComponent($0.rawValue, isDirectory: true) })
    try writer.write(Data(count: seconds * AudioImporter.sampleRate * 2))
}

private func headerDataSize(at url: URL) throws -> UInt32 {
    let header = try Data(contentsOf: url).subdata(in: 40 ..< 44)
    return UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
}

// MARK: - endedCaptures

@Test func aStopReportsTheCaptureEnded() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording())
    let ends = collectEnds(of: stage)
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)

    #expect(try await stage.stop(meetingID: fixture.id) == .captured)

    try await eventually { ends.value == [fixture.id] }
}

@Test func aStopWhoseFinalizeFailsReportsTheCaptureEnded() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording(stopError: FakeFailure(description: "disk gone")))
    let ends = collectEnds(of: stage)
    _ = try await stage.start(meetingID: fixture.id)

    #expect(try await stage.stop(meetingID: fixture.id) == .captureFailed)

    try await eventually { ends.value == [fixture.id] }
}

@Test func aFaultThatFailsTheCaptureReportsItEnded() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    let stage = fixture.stage(session: session)
    let ends = collectEnds(of: stage)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.permissionRevoked(.microphone))

    try await eventually { ends.value == [fixture.id] }
    #expect(try await fixture.meeting(fixture.id).state == "capture_failed")
}

@Test func aFailedStartReportsTheCaptureEnded() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording(startError: FakeFailure(description: "no tap")))
    let ends = collectEnds(of: stage)

    await #expect(throws: FakeFailure.self) {
        _ = try await stage.start(meetingID: fixture.id)
    }

    try await eventually { ends.value == [fixture.id] }
}

@Test func aSecondStopReportsNoSecondEnd() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording())
    let ends = collectEnds(of: stage)
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 1, for: fixture.id)
    _ = try await stage.stop(meetingID: fixture.id)
    try await eventually { ends.value == [fixture.id] }

    _ = try await stage.stop(meetingID: fixture.id)
    try await Task.sleep(for: .milliseconds(50))

    #expect(ends.value == [fixture.id])
}

// MARK: - Watchdog stats in the metadata

@Test func aStoppedCaptureWhoseWriteFailedIsCapturedWithTheWriteErrorAndRingCounts() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    session.stats.value = CaptureWatchdogStats(
        exactZeroSeconds: 1.5,
        rebuildCount: 1,
        systemRingDroppedChunkCount: 7,
        systemRingTruncatedChunkCount: 0,
        micRingDroppedChunkCount: 2,
        micRingTruncatedChunkCount: 1,
        firstWriteErrorDescription: "diskFull",
    )
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)
    try fixture.writeFinalizedWAV(seconds: 2, for: fixture.id)

    #expect(try await stage.stop(meetingID: fixture.id) == .captured)

    let completed = try await fixture.events(fixture.id).last
    #expect(completed?.event == "completed")
    let meta = try metadata(completed)
    #expect(meta.writeError == "diskFull")
    #expect(meta.micIncluded == true)
    #expect(meta.exactZeroSeconds == 1.5)
    #expect(meta.tapRebuilds == 1)
    #expect(meta.systemRingDroppedChunks == 7)
    #expect(meta.systemRingTruncatedChunks == 0)
    #expect(meta.micRingDroppedChunks == 2)
    #expect(meta.micRingTruncatedChunks == 1)
    let json = try #require(completed?.metadataJSON)
    for key in ["write_error", "system_ring_dropped_chunks", "system_ring_truncated_chunks", "mic_ring_dropped_chunks", "mic_ring_truncated_chunks"] {
        #expect(json.contains("\"\(key)\""))
    }
}

@Test func aFaultThatFailsAStartedCaptureRecordsItsStats() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording()
    session.stats.value = CaptureWatchdogStats(micRingDroppedChunkCount: 4, firstWriteErrorDescription: "diskFull")
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)

    session.emit(.permissionRevoked(.microphone))
    try await eventually { try await fixture.meeting(fixture.id).state == "capture_failed" }

    let meta = try await metadata(fixture.events(fixture.id).last)
    #expect(meta.errorClass == "permission_revoked_midstream")
    #expect(meta.micRingDroppedChunks == 4)
    #expect(meta.writeError == "diskFull")
}

@Test func aStartThatFailsRecordsNoStats() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording(startError: FakeFailure(description: "no tap"))
    session.stats.value = CaptureWatchdogStats(micRingDroppedChunkCount: 4)
    let stage = fixture.stage(session: session)

    _ = try? await stage.start(meetingID: fixture.id)

    let meta = try await metadata(fixture.events(fixture.id).last)
    #expect(meta == CaptureMeta(errorClass: "start_failed"))
}

// MARK: - Header repair after a failed finalize

@Test(arguments: ["stop", "fault"])
func aFailedFinalizeRepairsTheWAVHeaderAndFailsTheCapture(path: String) async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let session = fixture.recording(stopError: FakeFailure(description: "flush failed"))
    session.stats.value = CaptureWatchdogStats(firstWriteErrorDescription: "diskFull")
    let stage = fixture.stage(session: session)
    _ = try await stage.start(meetingID: fixture.id)
    try writeUnfinalizedWAV(seconds: 2, fixture: fixture)
    #expect(try headerDataSize(at: fixture.audioURL(fixture.id)) != UInt32(2 * AudioImporter.sampleRate * 2))

    if path == "stop" {
        #expect(try await stage.stop(meetingID: fixture.id) == .captureFailed)
    } else {
        session.emit(.permissionRevoked(.microphone))
        try await eventually { try await fixture.meeting(fixture.id).state == "capture_failed" }
    }

    #expect(try await fixture.meeting(fixture.id).state == "capture_failed")
    #expect(try headerDataSize(at: fixture.audioURL(fixture.id)) == UInt32(2 * AudioImporter.sampleRate * 2))
    #expect(try await metadata(fixture.events(fixture.id).last).writeError == "diskFull")
    #expect(fixture.captured.value.isEmpty)
}

@Test func aRepairThatFailsStillFailsTheCapture() async throws {
    let fixture = try StageFixture()
    defer { fixture.cleanUp() }
    let stage = fixture.stage(session: fixture.recording(stopError: FakeFailure(description: "flush failed")))
    _ = try await stage.start(meetingID: fixture.id)
    let url = fixture.audioURL(fixture.id)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try AtomicWriter.write(Data(repeating: 0x41, count: 4096), to: url)

    #expect(try await stage.stop(meetingID: fixture.id) == .captureFailed)

    #expect(try await metadata(fixture.events(fixture.id).last).errorClass == "interrupted")
    #expect(try Data(contentsOf: url) == Data(repeating: 0x41, count: 4096))
}
