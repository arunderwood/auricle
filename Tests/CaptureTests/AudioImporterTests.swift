import AVFoundation
@testable import Capture
import Core
import Foundation
import GRDB
@testable import State
import Telemetry
import Testing

/// A real in-memory store and a temporary cache root, so nothing touches the
/// real cache or database. Test audio is synthesized here, never checked in.
private struct ImporterFixture {
    let store: StateStore
    let root: URL
    let importer: AudioImporter

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws {
        store = try StateStore.forTesting(writer: DatabaseQueue())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("auricle-import-tests-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        importer = AudioImporter(
            stateStore: store,
            stageEventLogger: StageEventLogger(stateStore: store),
            cacheDirectory: { root.appendingPathComponent($0.rawValue, isDirectory: true) },
            now: { now },
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Entries under the cache root: empty when nothing was left behind.
    func cacheEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    func audioURL(_ id: MeetingID) -> URL {
        root.appendingPathComponent(id.rawValue).appendingPathComponent("audio.wav")
    }

    func sourceFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}

/// A sine tone of `seconds`, identical on every channel, written as a WAV
/// (16-bit PCM) at `sampleRate`.
private func writeTone(to url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    for channel in 0 ..< Int(channels) {
        let samples = try #require(buffer.floatChannelData)[channel]
        for frame in 0 ..< Int(frames) {
            samples[frame] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        }
    }
    try file.write(from: buffer)
}

private struct ReadAudio {
    let format: AVAudioFormat
    let length: AVAudioFramePosition
    let peak: Int16
}

private func readAudio(_ url: URL) throws -> ReadAudio {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = try #require(buffer.int16ChannelData)[0]
    let peak = (0 ..< Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
    return ReadAudio(format: file.fileFormat, length: file.length, peak: peak)
}

@Test func aSixteenKilohertzMonoWavPassesThrough() async throws {
    let fixture = try ImporterFixture()
    defer { fixture.cleanUp() }
    let source = fixture.sourceFile("call.wav")
    defer { try? FileManager.default.removeItem(at: source) }
    try writeTone(to: source, seconds: 2, sampleRate: 16000, channels: 1)

    let id = try await fixture.importer.importAudio(from: source)

    let audio = try readAudio(fixture.audioURL(id))
    #expect(audio.format.sampleRate == 16000)
    #expect(audio.format.channelCount == 1)
    #expect(audio.length == 32000)
    #expect(audio.peak > 10000)
}

@Test func aFortyEightKilohertzStereoInputIsConvertedToSixteenKilohertzMono() async throws {
    let fixture = try ImporterFixture()
    defer { fixture.cleanUp() }
    let source = fixture.sourceFile("call.wav")
    defer { try? FileManager.default.removeItem(at: source) }
    try writeTone(to: source, seconds: 3, sampleRate: 48000, channels: 2)

    let id = try await fixture.importer.importAudio(from: source)

    let audio = try readAudio(fixture.audioURL(id))
    #expect(audio.format.sampleRate == 16000)
    #expect(audio.format.channelCount == 1)
    #expect(abs(audio.length - 48000) <= 16)
    #expect(audio.peak > 10000)
}

@Test func theCachedAudioIsOwnerOnly() async throws {
    let fixture = try ImporterFixture()
    defer { fixture.cleanUp() }
    let source = fixture.sourceFile("call.wav")
    defer { try? FileManager.default.removeItem(at: source) }
    try writeTone(to: source, seconds: 1, sampleRate: 16000, channels: 1)

    let id = try await fixture.importer.importAudio(from: source)

    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.audioURL(id).path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
}

@Test func theMeetingRowAndCaptureEventCarryTheImportedFacts() async throws {
    let fixture = try ImporterFixture()
    defer { fixture.cleanUp() }
    let source = fixture.sourceFile("call.wav")
    defer { try? FileManager.default.removeItem(at: source) }
    try writeTone(to: source, seconds: 5, sampleRate: 16000, channels: 1)
    let started = try AudioImporter.parseStartedAt("2026-09-19T14:30:00Z")

    let id = try await fixture.importer.importAudio(from: source, startedAt: started, title: "Standup")

    let meeting = try #require(await fixture.store.fetchMeeting(id: id.rawValue))
    #expect(meeting.state == "captured")
    #expect(meeting.audioCachePath == fixture.audioURL(id).path)
    #expect(meeting.durationSeconds == 5)
    #expect(meeting.captureStartedAt == "2026-09-19T14:30:00Z")
    #expect(meeting.captureEndedAt == "2026-09-19T14:30:05Z")
    #expect(meeting.title == "Standup")
    #expect(meeting.verifiedAt == nil)

    let events = try await fixture.store.fetchStageEvents(meetingID: id.rawValue)
    #expect(events.count == 1)
    #expect(events[0].stage == "capture")
    #expect(events[0].event == "completed")
    let metadata = try #require(events[0].metadataJSON)
    let decoded = try #require(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
    #expect(decoded["imported"] as? Bool == true)
    #expect(decoded["source_format"] as? String == "wav")
    #expect(decoded["audio_duration_s"] as? Int == 5)
}

@Test func withoutStartedAtTheFileCreationDateIsUsed() async throws {
    let fixture = try ImporterFixture()
    defer { fixture.cleanUp() }
    let source = fixture.sourceFile("call.wav")
    defer { try? FileManager.default.removeItem(at: source) }
    try writeTone(to: source, seconds: 1, sampleRate: 16000, channels: 1)
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: source.path)

    let id = try await fixture.importer.importAudio(from: source)

    let meeting = try #require(await fixture.store.fetchMeeting(id: id.rawValue))
    #expect(meeting.captureStartedAt == ISO8601UTC.string(from: created))
    #expect(meeting.title == nil)
}

@Test func anUnreadableFileLeavesNoRowAndNoDirectory() async throws {
    let fixture = try ImporterFixture()
    defer { fixture.cleanUp() }
    let notAudio = fixture.sourceFile("notes.m4a")
    defer { try? FileManager.default.removeItem(at: notAudio) }
    try AtomicWriter.write(Data("this is not audio".utf8), to: notAudio)

    await #expect(throws: AudioImportError.unreadable) {
        try await fixture.importer.importAudio(from: notAudio)
    }
    await #expect(throws: AudioImportError.unreadable) {
        try await fixture.importer.importAudio(from: fixture.sourceFile("missing.wav"))
    }

    #expect(fixture.cacheEntries().isEmpty)
    #expect(try await fixture.store.fetchPending().isEmpty)
}

@Test func aZeroLengthWavLeavesNoRowAndNoDirectory() async throws {
    let fixture = try ImporterFixture()
    defer { fixture.cleanUp() }
    let empty = fixture.sourceFile("empty.wav")
    defer { try? FileManager.default.removeItem(at: empty) }
    try writeTone(to: empty, seconds: 0, sampleRate: 16000, channels: 1)

    await #expect(throws: AudioImportError.empty) {
        try await fixture.importer.importAudio(from: empty)
    }

    #expect(fixture.cacheEntries().isEmpty)
    #expect(try await fixture.store.fetchPending().isEmpty)
}

@Test func aMalformedStartedAtIsRejected() {
    #expect(throws: AudioImportError.malformedStartedAt) { try AudioImporter.parseStartedAt("yesterday") }
    #expect(throws: AudioImportError.malformedStartedAt) { try AudioImporter.parseStartedAt("") }
    #expect(throws: Never.self) { try AudioImporter.parseStartedAt("2026-09-19T14:30:00.250Z") }
}

@Test func twoImportsOfOneFileProduceTwoMeetings() async throws {
    let fixture = try ImporterFixture()
    defer { fixture.cleanUp() }
    let source = fixture.sourceFile("call.wav")
    defer { try? FileManager.default.removeItem(at: source) }
    try writeTone(to: source, seconds: 1, sampleRate: 16000, channels: 1)

    let first = try await fixture.importer.importAudio(from: source)
    let second = try await fixture.importer.importAudio(from: source)

    #expect(first != second)
    #expect(FileManager.default.fileExists(atPath: fixture.audioURL(first).path))
    #expect(FileManager.default.fileExists(atPath: fixture.audioURL(second).path))
    #expect(try await fixture.store.fetchPending().count == 2)
}

@Test func anAACM4AInputIsConverted() async throws {
    let fixture = try ImporterFixture()
    defer { fixture.cleanUp() }
    let source = fixture.sourceFile("call.m4a")
    defer { try? FileManager.default.removeItem(at: source) }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
    ]
    do {
        let file = try AVAudioFile(forWriting: source, settings: settings)
        let frames: AVAudioFrameCount = 44100 * 2
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0 ..< 2 {
            let samples = try #require(buffer.floatChannelData)[channel]
            for frame in 0 ..< Int(frames) {
                samples[frame] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / 44100))
            }
        }
        try file.write(from: buffer)
    }

    let id = try await fixture.importer.importAudio(from: source)

    let audio = try readAudio(fixture.audioURL(id))
    #expect(audio.format.sampleRate == 16000)
    #expect(audio.format.channelCount == 1)
    #expect(abs(audio.length - 32000) <= 2048)
    let events = try await fixture.store.fetchStageEvents(meetingID: id.rawValue)
    #expect(events[0].metadataJSON?.contains("\"source_format\":\"m4a\"") == true)
}
