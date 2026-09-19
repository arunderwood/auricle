import AVFoundation
@testable import Core
import Foundation
import GRDB
import Orchestrator
@testable import State
import Telemetry
import Testing
@testable import Transcribe
import TranscriberInterface

// MARK: - Transcriber stub

/// Returns a fixed transcript or throws a fixed error, and counts its calls
/// so a test can prove the transcriber was, or was never, reached.
actor StubTranscriber: TranscriberStrategy {
    private let result: Result<CanonicalTranscript, any Error>
    private(set) var callCount = 0
    private(set) var lastAudio: URL?
    private(set) var lastConfig: TranscriberConfig?

    init(_ result: Result<CanonicalTranscript, any Error>) {
        self.result = result
    }

    func transcribe(audio: URL, config: TranscriberConfig) async throws -> CanonicalTranscript {
        callCount += 1
        lastAudio = audio
        lastConfig = config
        return try result.get()
    }
}

/// An error whose message could leak transcript text if the stage ever
/// recorded it.
struct LeakyTranscriberError: Error, CustomStringConvertible {
    let secret: String
    var description: String {
        "leaked: \(secret)"
    }
}

func stubTranscript(_ texts: [String] = ["Hello there.", "General Kenobi."]) -> CanonicalTranscript {
    CanonicalTranscriptBuilder.build(texts.map { (speakerLabel: "Speaker_1", text: $0) })
}

// MARK: - WAV

/// A silent 16 kHz mono 16-bit PCM WAV of exactly `seconds`, written through
/// AVFoundation so the stage opens it the way it opens a real capture.
func writeSilentWAV(to url: URL, seconds: Double) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
    let frames = AVAudioFrameCount(seconds * 16000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    try file.write(from: buffer)
}

// MARK: - TranscribeStageFixture

/// A real in-memory store and a real `StageRunner`; only the transcriber is
/// stubbed. The stage reads and writes the meeting's real cache directory, so
/// `meetingID` is a fresh ULID and `cleanUp()` removes only its own
/// subdirectory. `queue` is the store's own database, for a test that needs to
/// break or change it underneath the store.
struct TranscribeStageFixture {
    let meetingID = MeetingID.generate()
    let queue: DatabaseQueue
    let store: StateStore
    let runner: StageRunner

    /// `insertMeetingRow: false` leaves the store without a row for `meetingID`.
    init(insertMeetingRow: Bool = true) async throws {
        queue = try DatabaseQueue()
        let resolvedStore = try StateStore.forTesting(writer: queue)
        store = resolvedStore
        runner = StageRunner(stateStore: resolvedStore, stageEventLogger: StageEventLogger(stateStore: resolvedStore))
        guard insertMeetingRow else { return }
        try await resolvedStore.insertMeeting(Meeting(
            id: meetingID.rawValue,
            state: "captured",
            createdAt: "2026-04-28T09:00:00Z",
            updatedAt: "2026-04-28T09:00:00Z",
            captureStartedAt: "2026-04-28T12:00:00Z",
        ))
    }

    func cleanUp() {
        guard let directory = try? CacheArtifactWriter.cacheDirectory(for: meetingID) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    func cacheDirectory() throws -> URL {
        try CacheArtifactWriter.cacheDirectory(for: meetingID)
    }

    func audioURL() throws -> URL {
        try cacheDirectory().appendingPathComponent("audio.wav")
    }

    func transcriptURL() throws -> URL {
        try cacheDirectory().appendingPathComponent("transcript.json")
    }

    func plantAudio(seconds: Double = 2) throws {
        try FileManager.default.createDirectory(at: cacheDirectory(), withIntermediateDirectories: true)
        try writeSilentWAV(to: audioURL(), seconds: seconds)
    }

    /// Bytes that are not audio at the path the stage reads audio from.
    func plantUnreadableAudio() throws {
        try FileManager.default.createDirectory(at: cacheDirectory(), withIntermediateDirectories: true)
        try AtomicWriter.write(Data("this is not a wav file".utf8), to: audioURL())
    }

    func run(transcriber: StubTranscriber, config: TranscriberConfig = TranscriberConfig()) async throws -> StageRunner.StageOutcome {
        try await TranscribeStage.run(meetingID: meetingID, stateStore: store, stageRunner: runner, transcriber: transcriber, config: config)
    }

    func readTranscript() throws -> CanonicalTranscript {
        try JSONDecoder().decode(CanonicalTranscript.self, from: Data(contentsOf: transcriptURL()))
    }

    /// `stage_events` in insertion order: `fetchStageEvents` orders by a
    /// second-resolution timestamp, which ties within a fast test.
    func events() async throws -> [StageEvent] {
        try await store.fetchStageEvents(meetingID: meetingID.rawValue).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    func state() async throws -> String? {
        try await store.fetchMeeting(id: meetingID.rawValue)?.state
    }
}

func metadataObject(_ event: StageEvent) throws -> [String: Any] {
    let json = try #require(event.metadataJSON)
    return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

/// The shape every failure row must have: the meeting parked in
/// `transcription_failed`, no `transcript.json`, a `failed` event carrying the
/// class, and the exit code the class maps to.
func expectTranscribeFailure(
    _ outcome: StageRunner.StageOutcome,
    fixture: TranscribeStageFixture,
    errorClass expectedClass: String,
    exitCode expectedExitCode: Int32,
) async throws {
    guard case let .failed(targetState, errorClass, errorMessage, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .transcriptionFailed)
    #expect(errorClass == expectedClass)
    #expect(TranscribeStage.exitCode(for: outcome) == expectedExitCode)
    #expect(try await fixture.state() == "transcription_failed")
    #expect(try !FileManager.default.fileExists(atPath: fixture.transcriptURL().path))

    let events = try await fixture.events()
    #expect(events.map(\.event) == ["started", "failed"])
    let failedEvent = try #require(events.last)
    #expect(failedEvent.errorMessage == errorMessage)
    #expect(try metadataObject(failedEvent)["error_class"] as? String == expectedClass)
}
