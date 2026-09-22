import Core
import Foundation

/// Streams PCM straight to `audio.wav` as it is produced — the one
/// recorded exemption from `AtomicWriter` (Decision 1.4, architecture.md's
/// `WAVWriter` note): a multi-hour capture cannot buffer its whole
/// recording in memory to write atomically at the end, so the file exists
/// and grows in place on a `FileHandle`, and only the RIFF/data chunk sizes
/// get patched after the fact.
///
/// The header is written twice: a placeholder goes out in `init`, built by
/// the same `AudioImporter.wavFile(pcm:)` that produces `AudioImporter`'s
/// header, so the two byte layouts can never drift apart. `finalize()` (or,
/// after a crash, `repairHeader(at:)`) then patches only offset 4 (RIFF
/// size) and offset 40 (data size) in place — the rest of the header and
/// every sample byte already on disk are untouched.
public final class WAVWriter {
    let handle: FileHandle
    private var bytesWritten: UInt64 = 0

    /// Creates `<cache>/<meetingID>/` at 0700 (`cacheDirectory(for:)` only
    /// computes the path, per `CacheArtifactWriter`) and `audio.wav` at
    /// 0600 inside it, then writes the placeholder header — a sample is
    /// never appended ahead of that.
    public init(
        meetingID: MeetingID,
        cacheDirectory: @escaping @Sendable (MeetingID) throws -> URL = { try CacheArtifactWriter.cacheDirectory(for: $0) },
    ) throws {
        let directory = try cacheDirectory(meetingID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )

        let url = directory.appendingPathComponent(AudioImporter.audioFileName)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.streamInterrupted(reason: "could not create \(AudioImporter.audioFileName) (errno \(errno))")
        }
        handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: AudioImporter.wavFile(pcm: Data()))
        } catch {
            throw Self.captureError(for: error)
        }
    }

    /// Appends PCM bytes at the current end of the file. A write failure
    /// leaves every byte already on disk exactly as it was — nothing here
    /// deletes or truncates the file, per Decision 1.4's exemption.
    public func write(_ samples: Data) throws {
        do {
            try handle.write(contentsOf: samples)
        } catch {
            throw Self.captureError(for: error)
        }
        bytesWritten += UInt64(samples.count)
    }

    /// Patches the RIFF and data chunk sizes from the bytes actually
    /// streamed and closes the file. Only meaningful after a stream that
    /// never threw — a `write` failure is Story 5.4's cue to fail the
    /// capture and recover the header later with `repairHeader(at:)`
    /// instead of finalizing here.
    public func finalize() throws {
        guard let dataSize = UInt32(exactly: bytesWritten) else {
            throw CaptureError.streamInterrupted(
                reason: "recorded \(bytesWritten) bytes, exceeding the 4 GiB WAV data-size field",
            )
        }
        defer { try? handle.close() }
        try Self.patchSizes(handle: handle, dataSize: dataSize)
    }

    /// Recovers a file whose header still holds `init`'s placeholder sizes
    /// — the shape a crash before `finalize()` leaves behind — by patching
    /// them from the file's actual size on disk, and returns the recovered
    /// duration.
    public static func repairHeader(at url: URL) throws -> TimeInterval {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? UInt64, fileSize >= 44 else {
            throw CaptureError.streamInterrupted(reason: "\(url.lastPathComponent) is smaller than a WAV header")
        }
        guard let dataSize = UInt32(exactly: fileSize - 44) else {
            throw CaptureError.streamInterrupted(
                reason: "\(url.lastPathComponent) is \(fileSize) bytes, exceeding the 4 GiB WAV data-size field",
            )
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try patchSizes(handle: handle, dataSize: dataSize)

        return TimeInterval(dataSize) / 2 / TimeInterval(AudioImporter.sampleRate)
    }

    // MARK: - Header patching

    private static func patchSizes(handle: FileHandle, dataSize: UInt32) throws {
        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: littleEndian(36 + dataSize))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: littleEndian(dataSize))
        } catch {
            throw captureError(for: error)
        }
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // MARK: - Error mapping

    /// `FileHandle.write(contentsOf:)` throws an `NSError` carrying the
    /// POSIX error under `NSUnderlyingErrorKey` rather than in its own
    /// domain/code — unwrap that to tell `ENOSPC` from every other failure.
    /// Not `private`, so a test can drive it with that exact wrapped shape
    /// instead of needing to fill a real disk.
    static func captureError(for error: Error) -> CaptureError {
        let nsError = error as NSError
        let posixCode = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map(\.code)
            ?? (nsError.domain == NSPOSIXErrorDomain ? nsError.code : nil)
        if posixCode == Int(ENOSPC) {
            return .diskFull
        }
        return .streamInterrupted(reason: nsError.localizedDescription)
    }
}
