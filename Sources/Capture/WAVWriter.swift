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
/// every sample byte already on disk are untouched, and both paths
/// `synchronize()` the patched bytes to disk before returning, so a power
/// loss right after `finalize()` can't leave the on-disk header pointing at
/// zero samples.
public final class WAVWriter {
    /// The largest `data` chunk size the 32-bit RIFF/data size fields can
    /// hold: `36 + dataSize` must itself fit in `UInt32` when patched.
    static let maxDataSize = UInt32.max - 36

    let handle: FileHandle
    private var bytesWritten: UInt64 = 0

    /// Creates `<cache>/<meetingID>/` at 0700 (`cacheDirectory(for:)` only
    /// computes the path, per `CacheArtifactWriter`, and the permissions are
    /// reapplied even when the directory already existed) and `audio.wav` at
    /// 0600 inside it, refusing if `audio.wav` already exists rather than
    /// silently overwriting it, then writes the placeholder header — a
    /// sample is never appended ahead of that.
    public init(
        meetingID: MeetingID,
        cacheDirectory: @escaping @Sendable (MeetingID) throws -> URL = { try CacheArtifactWriter.cacheDirectory(for: $0) },
    ) throws {
        let directory = try cacheDirectory(meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let url = directory.appendingPathComponent(AudioImporter.audioFileName)
        let fileDescriptor = url.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        guard fileDescriptor >= 0 else {
            throw CaptureError.streamInterrupted(reason: "could not create \(AudioImporter.audioFileName) (errno \(errno))")
        }
        handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: AudioImporter.wavFile(pcm: Data()))
        } catch {
            throw Self.captureError(for: error)
        }
    }

    /// Appends PCM bytes at the current end of the file. Rejects a write
    /// that isn't a whole number of 16-bit samples, and a write that would
    /// push the total past what the 32-bit `data` chunk size can hold,
    /// without writing any of it — the file on disk is left exactly as it
    /// was before the call in both cases. A write failure likewise leaves
    /// every byte already on disk exactly as it was — nothing here deletes
    /// or truncates the file, per Decision 1.4's exemption.
    public func write(_ samples: Data) throws {
        guard samples.count.isMultiple(of: 2) else {
            throw CaptureError.streamInterrupted(reason: "write of \(samples.count) bytes is not a whole number of 16-bit samples")
        }
        guard bytesWritten + UInt64(samples.count) <= UInt64(Self.maxDataSize) else {
            throw CaptureError.streamInterrupted(reason: "recording would exceed the 4 GiB WAV data-size field")
        }
        do {
            try handle.write(contentsOf: samples)
        } catch {
            throw Self.captureError(for: error)
        }
        bytesWritten += UInt64(samples.count)
    }

    /// Patches the RIFF and data chunk sizes from the bytes actually
    /// streamed, syncs them to disk, and closes the file. Only meaningful
    /// after a stream that never threw — a `write` failure is Story 5.2's
    /// cue to fail the capture and recover the header later with
    /// `repairHeader(at:)` instead of finalizing here.
    public func finalize() throws {
        defer { try? handle.close() }
        try Self.patchSizes(handle: handle, dataSize: UInt32(bytesWritten))
        try Self.sync(handle: handle)
    }

    /// Recovers a file whose header still holds `init`'s placeholder sizes
    /// — the shape a crash before `finalize()` leaves behind — by patching
    /// them from the file's actual size on disk, and returns the recovered
    /// duration. Refuses a file that isn't RIFF/WAVE/data-shaped rather than
    /// overwriting bytes 4-7 and 40-43 of whatever it is, and rounds an odd
    /// trailing byte (a crash mid-sample) down to the last whole sample.
    public static func repairHeader(at url: URL) throws -> TimeInterval {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? UInt64, fileSize >= 44 else {
            throw CaptureError.streamInterrupted(reason: "\(url.lastPathComponent) is smaller than a WAV header")
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try validateWAVHeader(handle: handle)

        let rawDataSize = fileSize - 44
        guard rawDataSize <= UInt64(maxDataSize) else {
            throw CaptureError.streamInterrupted(
                reason: "\(url.lastPathComponent) is \(fileSize) bytes, exceeding the 4 GiB WAV data-size field",
            )
        }
        let dataSize = UInt32(rawDataSize) & ~UInt32(1)

        try patchSizes(handle: handle, dataSize: dataSize)
        try sync(handle: handle)

        return TimeInterval(dataSize) / 2 / TimeInterval(AudioImporter.sampleRate)
    }

    // MARK: - Header patching

    /// Confirms `RIFF` at offset 0, `WAVE` at offset 8 and `data` at offset
    /// 36 before `repairHeader` overwrites anything — a file that doesn't
    /// carry this shape isn't one `WAVWriter` produced.
    private static func validateWAVHeader(handle: FileHandle) throws {
        do {
            try handle.seek(toOffset: 0)
            guard try handle.read(upToCount: 4) == Data("RIFF".utf8) else {
                throw CaptureError.streamInterrupted(reason: "not a RIFF file")
            }
            try handle.seek(toOffset: 8)
            guard try handle.read(upToCount: 4) == Data("WAVE".utf8) else {
                throw CaptureError.streamInterrupted(reason: "not a WAVE file")
            }
            try handle.seek(toOffset: 36)
            guard try handle.read(upToCount: 4) == Data("data".utf8) else {
                throw CaptureError.streamInterrupted(reason: "missing data chunk")
            }
        } catch let error as CaptureError {
            throw error
        } catch {
            throw captureError(for: error)
        }
    }

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

    private static func sync(handle: FileHandle) throws {
        do {
            try handle.synchronize()
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
