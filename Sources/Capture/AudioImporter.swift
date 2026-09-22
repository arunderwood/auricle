import AVFoundation
import Core
import Foundation
import State
import Telemetry

/// Why an import was refused. Each case's `message` is an actionable line for
/// the terminal and never contains the source path.
public enum AudioImportError: Error, Equatable {
    case malformedStartedAt
    case unreadable
    case empty
    case cacheUnavailable
    /// The meeting row and audio exist and `auricle run` works on them, but
    /// the `capture` event is missing.
    case eventNotRecorded(MeetingID)

    public var message: String {
        switch self {
        case .malformedStartedAt:
            "--started-at is not an ISO 8601 date-time (for example 2026-09-19T14:30:00Z)."
        case .unreadable:
            "the audio file could not be read. Check the path and that it is a WAV, m4a or another format macOS reads."
        case .empty:
            "the audio file holds no audio."
        case .cacheUnavailable:
            "the audio cache directory could not be written."
        case let .eventNotRecorded(id):
            "meeting \(id.rawValue) was registered but its capture event was not recorded."
        }
    }
}

/// The `capture` `completed` payload for an imported recording. It has its own
/// type because `Telemetry.CaptureMeta` is the live-capture story's to shape.
struct ImportedCaptureMeta: Encodable {
    let imported = true
    let sourceFormat: String
    let audioDurationSeconds: Int

    enum CodingKeys: String, CodingKey {
        case imported
        case sourceFormat = "source_format"
        case audioDurationSeconds = "audio_duration_s"
    }
}

/// Registers an existing recording as a `captured` meeting (Story 4.8): the
/// audio becomes the Decision 1.4 capture format (PCM 16-bit, 16 kHz, mono
/// WAV) at `<cache>/<meeting-id>/audio.wav`, mode 0600.
///
/// The audio is complete on disk before the meeting row exists, so a failed
/// import leaves neither a row nor a cache directory behind.
public struct AudioImporter: Sendable {
    static let sampleRate = 16000
    static let audioFileName = "audio.wav"

    private static let log = Log(category: "audio-importer")

    private let stateStore: StateStore
    private let stageEventLogger: StageEventLogger
    private let cacheDirectory: @Sendable (MeetingID) throws -> URL
    private let now: @Sendable () -> Date

    /// `cacheDirectory` and `now` are injectable so a test writes under a
    /// temporary root and pins the clock.
    public init(
        stateStore: StateStore,
        stageEventLogger: StageEventLogger,
        cacheDirectory: @escaping @Sendable (MeetingID) throws -> URL = { try CacheArtifactWriter.cacheDirectory(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.stateStore = stateStore
        self.stageEventLogger = stageEventLogger
        self.cacheDirectory = cacheDirectory
        self.now = now
    }

    /// Parses a `--started-at` value. Whole-second and fractional-second
    /// forms are both accepted.
    public static func parseStartedAt(_ text: String) throws -> Date {
        guard let date = ISO8601UTC.date(from: text) else { throw AudioImportError.malformedStartedAt }
        return date
    }

    /// Returns the new meeting's id. Two imports of one file yield two ids.
    public func importAudio(from source: URL, startedAt: Date? = nil, title: String? = nil) async throws -> MeetingID {
        let pcm = try Self.convert(source)
        let duration = Int((Double(pcm.frameCount) / Double(Self.sampleRate)).rounded())
        let start = startedAt ?? Self.creationDate(of: source) ?? now()

        let id = MeetingID.generate()
        let audioURL = try store(pcm, for: id)
        let directory = audioURL.deletingLastPathComponent()

        let stamp = ISO8601UTC.string(from: now())
        do {
            try await stateStore.insertMeeting(Meeting(
                id: id.rawValue,
                state: PipelineState.captured.rawValue,
                createdAt: stamp,
                updatedAt: stamp,
                captureStartedAt: ISO8601UTC.string(from: start),
                captureEndedAt: ISO8601UTC.string(from: start.addingTimeInterval(TimeInterval(duration))),
                durationSeconds: duration,
                title: title,
                audioCachePath: audioURL.path,
            ))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let meta = ImportedCaptureMeta(
            sourceFormat: Self.sourceFormat(of: source),
            audioDurationSeconds: duration,
        )
        do {
            try await stageEventLogger.record(event: StageEventRecord(
                meetingID: id,
                stage: .capture,
                kind: .completed,
                occurredAt: stamp,
                targetState: .captured,
                metadataJSON: String(bytes: JSONEncoder().encode(meta), encoding: .utf8),
            ))
        } catch {
            throw AudioImportError.eventNotRecorded(id)
        }

        Self.log.info("Imported audio", [
            "meeting_id": .publicSafe(id.rawValue),
            "duration_s": .publicSafe(duration),
        ])
        return id
    }

    /// Writes the audio under the meeting's cache directory and returns its
    /// URL. A failure removes the directory it created.
    private func store(_ pcm: PCM, for id: MeetingID) throws -> URL {
        let directory: URL
        do {
            directory = try cacheDirectory(id)
        } catch {
            throw AudioImportError.cacheUnavailable
        }
        let audioURL = directory.appendingPathComponent(Self.audioFileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try AtomicWriter.write(Self.wavFile(pcm: pcm.samples), to: audioURL, permissions: 0o600)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw AudioImportError.cacheUnavailable
        }
        return audioURL
    }

    // MARK: - Conversion

    private struct PCM {
        var samples: Data
        var frameCount: Int
    }

    /// Feeds an `AVAudioConverter` from a file, one buffer at a time. A
    /// class because the converter's input block is `@Sendable` and cannot
    /// capture mutable locals; the block runs synchronously inside `convert`,
    /// so nothing is shared across threads.
    private final class Reader: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var failed = false

        init?(file: AVAudioFile) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return nil }
            self.file = file
            self.buffer = buffer
        }

        /// Reads only the frames the file still holds: a read at or past the
        /// end throws rather than returning an empty buffer.
        func next() -> AVAudioBuffer? {
            let remaining = file.length - file.framePosition
            guard remaining > 0 else { return nil }
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, AVAudioFramePosition(buffer.frameCapacity))))
            } catch {
                failed = true
                return nil
            }
            return buffer.frameLength == 0 ? nil : buffer
        }
    }

    private static func convert(_ source: URL) throws -> PCM {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: source)
        } catch {
            throw AudioImportError.unreadable
        }
        guard file.length > 0 else { throw AudioImportError.empty }

        guard
            let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: file.processingFormat, to: target),
            let reader = Reader(file: file),
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)
        else { throw AudioImportError.unreadable }

        var samples = Data()
        var frameCount = 0
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if let buffer = reader.next() {
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error || reader.failed {
                throw AudioImportError.unreadable
            }

            let frames = Int(output.frameLength)
            if frames > 0, let channel = output.int16ChannelData {
                samples.append(Data(bytes: channel[0], count: frames * MemoryLayout<Int16>.size))
                frameCount += frames
            }
            if status == .endOfStream {
                break
            }
        }

        guard frameCount > 0 else { throw AudioImportError.empty }
        return PCM(samples: samples, frameCount: frameCount)
    }

    /// A canonical 44-byte RIFF/WAVE header followed by the samples. Also
    /// `WAVWriter`'s source for that same 44-byte layout — an empty `pcm`
    /// yields just the header, which is what a streaming writer needs as its
    /// placeholder before it knows the final size.
    static func wavFile(pcm samples: Data) -> Data {
        var data = Data()
        func append(_ text: String) {
            data.append(Data(text.utf8))
        }
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        append("RIFF")
        append(UInt32(36 + samples.count))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1)) // linear PCM
        append(UInt16(1)) // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2)) // bytes per frame
        append(UInt16(16)) // bits per sample
        append("data")
        append(UInt32(samples.count))
        data.append(samples)
        return data
    }

    // MARK: - Source metadata

    private static func creationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.creationDate] as? Date) ?? (attributes?[.modificationDate] as? Date)
    }

    private static func sourceFormat(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "unknown" : ext
    }
}
