import Core
import Foundation
import Testing
import Transcribe
import TranscriberInterface
import WhisperKitTranscriber

/// The 30-minute budget needs the reference recording and a provisioned
/// model, neither of which CI has, so this runs only where both are named:
/// `AURICLE_REFERENCE_WAV_30MIN` is a 30-minute speech recording and
/// `AURICLE_WHISPERKIT_MODEL_FOLDER` the model's variant folder, with its
/// tokenizer beside it or under the default model root. Everywhere else the
/// test is skipped, which reports the budget as unverified rather than met.
private enum Reference {
    static let audio = ProcessInfo.processInfo.environment["AURICLE_REFERENCE_WAV_30MIN"]
    static let modelFolder = ProcessInfo.processInfo.environment["AURICLE_WHISPERKIT_MODEL_FOLDER"]
    static var isAvailable: Bool {
        audio != nil && modelFolder != nil
    }
}

/// NFR-P3: transcribe finishes in 30 seconds or less for 30 minutes of audio.
/// The clock covers the whole stage, model load included, because the worker
/// is a fresh process per meeting and pays that load every time.
private let transcribeBudget: Duration = .seconds(30)

@Test(.enabled(if: Reference.isAvailable, "needs AURICLE_REFERENCE_WAV_30MIN and AURICLE_WHISPERKIT_MODEL_FOLDER"))
func thirtyMinutesOfAudioTranscribesWithinTheBudget() async throws {
    let audio = try #require(Reference.audio)
    let modelFolder = try #require(Reference.modelFolder)
    let fixture = try await TranscribeStageFixture()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(at: fixture.cacheDirectory(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: audio), to: fixture.audioURL())
    let config = TranscriberConfig(modelFolder: URL(fileURLWithPath: modelFolder, isDirectory: true))

    let clock = ContinuousClock()
    let start = clock.now
    let outcome = try await TranscribeStage.run(
        meetingID: fixture.meetingID,
        stateStore: fixture.store,
        stageRunner: fixture.runner,
        transcriber: WhisperKitTranscriber(),
        config: config,
    )
    let elapsed = clock.now - start

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(elapsed <= transcribeBudget, "transcribing took \(elapsed); the budget is \(transcribeBudget)")
}
