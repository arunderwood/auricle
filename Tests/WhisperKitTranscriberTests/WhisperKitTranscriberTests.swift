import AVFoundation
import Core
import Foundation
import Testing
import TranscriberInterface
@testable import WhisperKitTranscriber

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auricle-whisperkit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeSilentWAV(to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000))
    buffer.frameLength = 16000
    try file.write(from: buffer)
}

// MARK: - Failures that happen before a model is involved

@Test func anUnprovisionedModelFailsAsUnavailableWithoutLoadingAnything() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = directory.appendingPathComponent("audio.wav")
    try writeSilentWAV(to: audio)
    let transcriber = WhisperKitTranscriber(store: WhisperKitModelStore(root: directory.appendingPathComponent("models")))

    await #expect(throws: TranscriberError.modelUnavailable) {
        _ = try await transcriber.transcribe(audio: audio, config: TranscriberConfig())
    }

    #expect(await transcriber.modelLoadCount == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("models").path))
}

@Test func missingAudioFailsAsUnreadableBeforeTheModelIsResolved() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transcriber = WhisperKitTranscriber(store: WhisperKitModelStore(root: directory))

    await #expect(throws: TranscriberError.audioUnreadable) {
        _ = try await transcriber.transcribe(audio: directory.appendingPathComponent("absent.wav"), config: TranscriberConfig())
    }
}

@Test func aFileThatIsNotAudioFailsAsUnreadable() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let notAudio = directory.appendingPathComponent("audio.wav")
    try AtomicWriter.write(Data("not audio".utf8), to: notAudio)
    let transcriber = WhisperKitTranscriber(store: WhisperKitModelStore(root: directory))

    await #expect(throws: TranscriberError.audioUnreadable) {
        _ = try await transcriber.transcribe(audio: notAudio, config: TranscriberConfig())
    }
}

// MARK: - A model that is present but cannot be loaded

/// The store's completeness check passes on any non-empty `.mlmodelc`
/// directory, so stub bundles get past it and fail inside WhisperKit's own
/// model load, which runs before it would look for a tokenizer or the
/// network.
@Test func aModelThatCannotBeLoadedFailsAsLoadFailedAndLeavesNoPendingLoad() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let folder = try fixture.defaultFolder
    try fixture.plantAllModels(in: folder)
    try fixture.plantTokenizer(in: folder)
    let audio = fixture.root.appendingPathComponent("audio.wav")
    try writeSilentWAV(to: audio)
    let transcriber = WhisperKitTranscriber(store: fixture.store)

    await #expect(throws: TranscriberError.modelLoadFailed) {
        _ = try await transcriber.transcribe(audio: audio, config: TranscriberConfig())
    }
    #expect(await transcriber.modelLoadCount == 0)

    await #expect(throws: TranscriberError.modelLoadFailed) {
        _ = try await transcriber.transcribe(audio: audio, config: TranscriberConfig())
    }
    #expect(await transcriber.modelLoadCount == 0)
}

// MARK: - Live model

/// Runs only where a model has been provisioned by hand:
/// `AURICLE_WHISPERKIT_MODEL_FOLDER` names the model's variant folder, whose
/// tokenizer must sit beside it or under the default model root, and
/// `AURICLE_REFERENCE_WAV` names a short speech recording. Everywhere else it
/// is skipped, never downloading anything.
private enum LiveModel {
    static let folder = ProcessInfo.processInfo.environment["AURICLE_WHISPERKIT_MODEL_FOLDER"]
    static let audio = ProcessInfo.processInfo.environment["AURICLE_REFERENCE_WAV"]
    static var isAvailable: Bool {
        folder != nil && audio != nil
    }
}

@Test(.enabled(if: LiveModel.isAvailable, "needs AURICLE_WHISPERKIT_MODEL_FOLDER and AURICLE_REFERENCE_WAV"))
func aLoadedModelIsReusedAndARerunIsByteIdentical() async throws {
    let folder = try #require(LiveModel.folder)
    let audio = try #require(LiveModel.audio)
    let config = TranscriberConfig(modelFolder: URL(fileURLWithPath: folder, isDirectory: true))
    let transcriber = WhisperKitTranscriber()

    let first = try await transcriber.transcribe(audio: URL(fileURLWithPath: audio), config: config)
    let second = try await transcriber.transcribe(audio: URL(fileURLWithPath: audio), config: config)

    #expect(await transcriber.modelLoadCount == 1)
    #expect(first == second)
    #expect(Array(first.text.unicodeScalars) == Array(first.text.precomposedStringWithCanonicalMapping.unicodeScalars))
    #expect(!first.text.contains("\r"))
    #expect(!first.text.contains("<|"))

    let firstID = MeetingID.generate()
    let secondID = MeetingID.generate()
    defer {
        for id in [firstID, secondID] {
            if let directory = try? CacheArtifactWriter.cacheDirectory(for: id) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
    try CacheArtifactWriter.write(first, for: firstID, named: "transcript.json", schemaVersion: 1)
    try CacheArtifactWriter.write(second, for: secondID, named: "transcript.json", schemaVersion: 1)
    let firstBytes = try Data(contentsOf: CacheArtifactWriter.cacheDirectory(for: firstID).appendingPathComponent("transcript.json"))
    let secondBytes = try Data(contentsOf: CacheArtifactWriter.cacheDirectory(for: secondID).appendingPathComponent("transcript.json"))
    #expect(firstBytes == secondBytes)
}
