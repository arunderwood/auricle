import Core
import Diarize
import DiarizerInterface
import Foundation
import Testing
import WhisperKitDiarizer

/// The 30-minute budget needs the reference recording and provisioned models,
/// neither of which CI has, so this runs only where both are named:
/// `AURICLE_REFERENCE_WAV_30MIN` is a 30-minute speech recording and
/// `AURICLE_SPEAKERKIT_MODEL_FOLDER` the SpeakerKit repository folder holding
/// `speaker_segmenter`, `speaker_embedder` and `speaker_clusterer`. Everywhere
/// else the test is skipped, which reports the budget as unverified, not met.
private enum Reference {
    static let audio = ProcessInfo.processInfo.environment["AURICLE_REFERENCE_WAV_30MIN"]
    static let modelFolder = ProcessInfo.processInfo.environment["AURICLE_SPEAKERKIT_MODEL_FOLDER"]
    static var isAvailable: Bool {
        audio != nil && modelFolder != nil
    }
}

/// NFR-P3: diarize finishes in 30 seconds or less for 30 minutes of audio,
/// model load included, because the worker is a fresh process per meeting.
private let diarizeBudget: Duration = .seconds(30)

@Test(.enabled(if: Reference.isAvailable, "needs AURICLE_REFERENCE_WAV_30MIN and AURICLE_SPEAKERKIT_MODEL_FOLDER"))
func thirtyMinutesOfAudioDiarizesWithinTheBudget() async throws {
    let audio = try #require(Reference.audio)
    let modelFolder = try #require(Reference.modelFolder)
    let fixture = DiarizeFixture()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(at: fixture.cacheDirectory(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: audio), to: fixture.audioURL())
    let config = DiarizerConfig(modelFolder: URL(fileURLWithPath: modelFolder, isDirectory: true))

    let clock = ContinuousClock()
    let start = clock.now
    let meta = try await DiarizeStage.run(
        meetingID: fixture.meetingID,
        transcript: CanonicalTranscriptBuilder.build([]),
        utteranceTimings: [],
        audio: fixture.audioURL(),
        diarizer: WhisperKitDiarizer(),
        config: config,
    )
    let elapsed = clock.now - start

    #expect(meta.segmentCount > 0)
    #expect(elapsed <= diarizeBudget, "diarizing took \(elapsed); the budget is \(diarizeBudget)")
}
