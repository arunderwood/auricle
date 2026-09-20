import AIReviewerInterface
@testable import Attribute
@testable import Core
import DiarizerInterface
import Foundation
import GRDB
import Orchestrator
@testable import State
import Telemetry
import Testing

func segment(_ id: String, _ label: String, _ start: Double, _ end: Double, utterances: ClosedRange<Int>? = nil) -> DiarizedSegment {
    DiarizedSegment(
        id: id, speakerLabel: label, startSeconds: start, endSeconds: end,
        utteranceIndex: utterances.map { DiarizedUtteranceRange(first: $0.lowerBound, last: $0.upperBound) },
        voiceProfile: DiarizedVoiceProfile(overlapRatio: 0),
    )
}

/// Three speakers; `Speaker_2` speaks longest.
let threeSpeakerDiarization = DiarizationArtifact(segments: [
    segment("seg_1", "Speaker_1", 0, 5, utterances: 0 ... 0),
    segment("seg_2", "Speaker_2", 5, 25, utterances: 1 ... 1),
    segment("seg_3", "Speaker_3", 25, 30, utterances: 2 ... 2),
])

let threeSpeakerTranscript = CanonicalTranscriptBuilder.build([
    (speakerLabel: "Speaker_1", text: "Hello there."),
    (speakerLabel: "Speaker_2", text: "Let us begin."),
    (speakerLabel: "Speaker_3", text: "Sounds good."),
])

/// A real in-memory store and a real `StageRunner`. The meeting starts in
/// `awaiting_attribution`, where the review stage leaves it.
struct AttributeFixture {
    let meetingID = MeetingID.generate()
    let store: StateStore
    let runner: StageRunner
    let recorder: TelemetryRecorder

    init(state: String = "awaiting_attribution") async throws {
        store = try StateStore.forTesting(writer: DatabaseQueue())
        runner = StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store))
        recorder = TelemetryRecorder(stateStore: store)
        try await store.insertMeeting(Meeting(
            id: meetingID.rawValue, state: state,
            createdAt: "2026-04-28T09:00:00Z", updatedAt: "2026-04-28T09:00:00Z",
            captureStartedAt: "2026-04-28T12:00:00Z",
        ))
    }

    func cleanUp() {
        guard let directory = try? CacheArtifactWriter.cacheDirectory(for: meetingID) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    func url(_ name: String) throws -> URL {
        try CacheArtifactWriter.cacheDirectory(for: meetingID).appendingPathComponent(name)
    }

    func exists(_ name: String) -> Bool {
        guard let url = try? url(name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes the immutable inputs and returns their bytes.
    @discardableResult
    func plantInputs(diarization: DiarizationArtifact = threeSpeakerDiarization) throws -> (transcript: Data, diarization: Data) {
        try CacheArtifactWriter.write(threeSpeakerTranscript, for: meetingID, named: "transcript.json", schemaVersion: 1)
        try CacheArtifactWriter.write(diarization, for: meetingID, named: "diarization.json", schemaVersion: 1)
        return try (Data(contentsOf: url("transcript.json")), Data(contentsOf: url("diarization.json")))
    }

    func run(_ mode: AttributionStage.Mode, glossary: Glossary = Glossary()) async -> WorkerExitStatus {
        await AttributionStage.execute(
            meetingID: meetingID, mode: mode, stateStore: store, stageRunner: runner,
            telemetryRecorder: recorder, glossary: glossary,
        )
    }

    func readAttribution() throws -> AttributionFile {
        try JSONDecoder().decode(AttributionFile.self, from: Data(contentsOf: url(AttributionFile.fileName)))
    }

    func rawAttribution() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url(AttributionFile.fileName))) as? [String: Any])
    }

    func events() async throws -> [StageEvent] {
        try await store.fetchStageEvents(meetingID: meetingID.rawValue).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    func state() async throws -> String? {
        try await store.fetchMeeting(id: meetingID.rawValue)?.state
    }
}
