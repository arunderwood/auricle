import AVFoundation
@testable import Capture
import Core
import Foundation
import Testing

/// A temporary cache root, mirroring `ImporterFixture` in
/// `AudioImporterTests`: a fresh `MeetingID` and an injectable
/// `cacheDirectory` so nothing touches the real cache.
private struct WriterFixture {
    let meetingID = MeetingID.generate()
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auricle-wavwriter-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeWriter() throws -> WAVWriter {
        try WAVWriter(meetingID: meetingID, cacheDirectory: { root.appendingPathComponent($0.rawValue, isDirectory: true) })
    }

    func directory() -> URL {
        root.appendingPathComponent(meetingID.rawValue, isDirectory: true)
    }

    func audioURL() -> URL {
        directory().appendingPathComponent(AudioImporter.audioFileName)
    }
}

private func permissions(of url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}

/// A tone of `seconds` at 16 kHz mono 16-bit, as raw little-endian PCM
/// bytes (no header) — the shape `WAVWriter.write` consumes.
private func tonePCM(seconds: Double, sampleRate: Double = 16000) -> Data {
    let frames = Int(seconds * sampleRate)
    var data = Data(capacity: frames * 2)
    for frame in 0 ..< frames {
        let sample = Int16(0.5 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 32767)
        withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

/// Serialized: several of these open an `AVAudioFile` to verify the WAV
/// `WAVWriter` produced, and `AudioImporterTests` in this same target does
/// the same. Enough concurrent `AVAudioFile` instances across the process
/// makes AudioToolbox's codec-component loading flaky, so this suite runs
/// its own tests one at a time rather than adding to that count.
@Suite(.serialized)
struct WAVWriterTests {
    @Test func theCacheDirectoryAndAudioFileExistBeforeAnySampleIsWritten() throws {
        let fixture = WriterFixture()
        defer { fixture.cleanUp() }

        _ = try fixture.makeWriter()

        #expect(try permissions(of: fixture.directory()) == 0o700)
        #expect(try permissions(of: fixture.audioURL()) == 0o600)
        #expect(try Data(contentsOf: fixture.audioURL()).count == 44)
    }

    @Test func finalizeProducesAReadableWavWithTheCorrectFrameCount() throws {
        let fixture = WriterFixture()
        defer { fixture.cleanUp() }
        let writer = try fixture.makeWriter()
        let pcm = tonePCM(seconds: 2)

        try writer.write(pcm)
        try writer.finalize()

        let bytes = try Data(contentsOf: fixture.audioURL())
        let riffSize = bytes[4 ..< 8].withUnsafeBytes { $0.load(as: UInt32.self) }
        let dataSize = bytes[40 ..< 44].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(Int(dataSize) == pcm.count)
        #expect(Int(riffSize) == 36 + pcm.count)

        let file = try AVAudioFile(forReading: fixture.audioURL(), commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(Int(file.length) == pcm.count / 2)
    }

    @Test func writingInMultipleChunksAccumulatesCorrectly() throws {
        let fixture = WriterFixture()
        defer { fixture.cleanUp() }
        let writer = try fixture.makeWriter()
        let chunks = (0 ..< 5).map { _ in tonePCM(seconds: 0.25) }

        for chunk in chunks {
            try writer.write(chunk)
        }
        try writer.finalize()

        let expectedBytes = chunks.reduce(0) { $0 + $1.count }
        let bytes = try Data(contentsOf: fixture.audioURL())
        #expect(bytes.count == 44 + expectedBytes)
        let dataSize = bytes[40 ..< 44].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(Int(dataSize) == expectedBytes)
    }

    @Test func repairHeaderPatchesSizesFromFileSizeAndReturnsDuration() throws {
        let fixture = WriterFixture()
        defer { fixture.cleanUp() }
        let writer = try fixture.makeWriter()
        let pcm = tonePCM(seconds: 3)
        try writer.write(pcm)
        // No finalize() — the header still holds init's placeholder sizes,
        // simulating a crash between the last write and finalize().

        let recovered = try WAVWriter.repairHeader(at: fixture.audioURL())

        #expect(recovered == 3)
        let bytes = try Data(contentsOf: fixture.audioURL())
        let riffSize = bytes[4 ..< 8].withUnsafeBytes { $0.load(as: UInt32.self) }
        let dataSize = bytes[40 ..< 44].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(Int(dataSize) == pcm.count)
        #expect(Int(riffSize) == 36 + pcm.count)

        let file = try AVAudioFile(forReading: fixture.audioURL(), commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(Int(file.length) == pcm.count / 2)
    }

    @Test func aNonSpaceWriteFailureIsStreamInterruptedAndLeavesThePartialFileOnDisk() throws {
        let fixture = WriterFixture()
        defer { fixture.cleanUp() }
        let writer = try fixture.makeWriter()
        try writer.write(tonePCM(seconds: 0.1))
        let bytesBeforeFailure = try Data(contentsOf: fixture.audioURL())

        // Closing the raw descriptor out from under the handle forces the
        // next write to fail with EBADF — a real, non-ENOSPC POSIX failure,
        // without needing an actually full disk.
        close(writer.handle.fileDescriptor)

        do {
            try writer.write(tonePCM(seconds: 0.1))
            Issue.record("expected write to throw")
        } catch let CaptureError.streamInterrupted(reason) {
            #expect(!reason.isEmpty)
        } catch {
            Issue.record("expected .streamInterrupted, got \(error)")
        }

        let bytesAfterFailure = try Data(contentsOf: fixture.audioURL())
        #expect(bytesAfterFailure == bytesBeforeFailure)
    }

    @Test func aSimulatedENOSPCErrorMapsToDiskFull() {
        guard case .diskFull = WAVWriter.captureError(for: simulatedENOSPCError()) else {
            Issue.record("expected .diskFull, got \(WAVWriter.captureError(for: simulatedENOSPCError()))")
            return
        }
    }

    @Test func aNonSpacePosixErrorMapsToStreamInterrupted() {
        let ebadf = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF)),
        ])
        guard case .streamInterrupted = WAVWriter.captureError(for: ebadf) else {
            Issue.record("expected .streamInterrupted, got \(WAVWriter.captureError(for: ebadf))")
            return
        }
    }

    @Test func repairHeaderOnAHeaderOnlyFileRecoversZeroDuration() throws {
        let fixture = WriterFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.makeWriter()
        // No write() at all — the crash-before-any-sample case: the file on
        // disk is exactly init's 44-byte placeholder header.

        let recovered = try WAVWriter.repairHeader(at: fixture.audioURL())

        #expect(recovered == 0)
        let bytes = try Data(contentsOf: fixture.audioURL())
        let riffSize = bytes[4 ..< 8].withUnsafeBytes { $0.load(as: UInt32.self) }
        let dataSize = bytes[40 ..< 44].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(dataSize == 0)
        #expect(riffSize == 36)
    }

    @Test func repairHeaderRejectsAFileSmallerThanAHeader() throws {
        let fixture = WriterFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory(), withIntermediateDirectories: true)
        try Data("too short".utf8).write(to: fixture.audioURL())

        #expect(throws: CaptureError.self) {
            try WAVWriter.repairHeader(at: fixture.audioURL())
        }
    }
}

/// `FileHandle.write(contentsOf:)` on a real full volume throws an
/// `NSError` in `NSCocoaErrorDomain` whose `NSUnderlyingErrorKey` carries
/// the actual POSIX error — confirmed empirically against a disk image
/// filled past capacity: `Error Domain=NSCocoaErrorDomain Code=640
/// "..." UserInfo={NSUnderlyingError=... Domain=NSPOSIXErrorDomain
/// Code=28 "No space left on device"}}`. Reproducing that exact shape here
/// exercises `WAVWriter.captureError(for:)`'s unwrapping deterministically,
/// without mounting and filling a real volume on every test run.
private func simulatedENOSPCError() -> NSError {
    NSError(
        domain: NSCocoaErrorDomain,
        code: 640,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))],
    )
}
