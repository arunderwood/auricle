import AIReviewerInterface
@testable import Core
import DiarizerInterface
import Foundation
import GRDB
import Orchestrator
@testable import ReviewDiarization
@testable import State
import Telemetry
import Testing

/// Answers with a fixed result or error, optionally after a delay that
/// ignores cancellation, and counts its calls.
actor StubReviewer: DiarizationReviewerStrategy {
    enum Behavior {
        case succeed(AIReviewerResult<DiarizationSuggestion>)
        case fail(any Error)
        case hang(seconds: Double)
    }

    private let behavior: Behavior
    private(set) var callCount = 0
    private(set) var lastConfig: AIReviewerConfig?

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func review(input _: DiarizationReviewInput, config: AIReviewerConfig) async throws -> AIReviewerResult<DiarizationSuggestion> {
        callCount += 1
        lastConfig = config
        switch behavior {
        case let .succeed(result): return result
        case let .fail(error): throw error
        case let .hang(seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return AIReviewerResult(suggestions: [], cost: AIReviewerCost(inputTokens: 0, outputTokens: 0, costUSD: 0, modelID: "late"), reviewedSegmentCount: 0)
        }
    }
}

struct LeakyReviewerError: Error, CustomStringConvertible {
    let secret: String
    var description: String {
        "leaked: \(secret)"
    }
}

func stubSuggestion(_ id: String) -> DiarizationSuggestion {
    DiarizationSuggestion(suggestionId: id, reasoning: "because", kind: .underSegmentation, segmentId: "seg_1", proposedSplits: [])
}

func stubResult(suggestions: [DiarizationSuggestion], model: String = "claude-haiku-4-5") -> AIReviewerResult<DiarizationSuggestion> {
    AIReviewerResult(
        suggestions: suggestions,
        cost: AIReviewerCost(inputTokens: 1200, outputTokens: 80, costUSD: 0.03, modelID: model),
        reviewedSegmentCount: 4,
    )
}

/// A real in-memory store and a real `StageRunner`; only the reviewer is
/// stubbed. The meeting starts in `transcribing`, where the transcribe stage
/// leaves it.
struct ReviewFixture {
    let meetingID = MeetingID.generate()
    let queue: DatabaseQueue
    let store: StateStore
    let runner: StageRunner
    let recorder: TelemetryRecorder

    init(insertMeetingRow: Bool = true) async throws {
        queue = try DatabaseQueue()
        store = try StateStore.forTesting(writer: queue)
        runner = StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store))
        recorder = TelemetryRecorder(stateStore: store)
        guard insertMeetingRow else { return }
        try await store.insertMeeting(Meeting(
            id: meetingID.rawValue,
            state: "transcribing",
            createdAt: "2026-04-28T09:00:00Z",
            updatedAt: "2026-04-28T09:00:00Z",
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

    /// Writes the two immutable inputs and returns their bytes.
    @discardableResult
    func plantInputs() throws -> (transcript: Data, diarization: Data) {
        let transcript = CanonicalTranscriptBuilder.build([(speakerLabel: "Speaker_1", text: "Hello there.")])
        let diarization = DiarizationArtifact(segments: [
            DiarizedSegment(id: "seg_1", speakerLabel: "Speaker_1", startSeconds: 0, endSeconds: 2, utteranceIndex: nil, voiceProfile: DiarizedVoiceProfile(overlapRatio: 0)),
        ])
        try CacheArtifactWriter.write(transcript, for: meetingID, named: "transcript.json", schemaVersion: 1)
        try CacheArtifactWriter.write(diarization, for: meetingID, named: "diarization.json", schemaVersion: 1)
        return try (Data(contentsOf: url("transcript.json")), Data(contentsOf: url("diarization.json")))
    }

    func run(
        reviewer: StubReviewer,
        settings: ReviewDiarizationSettings,
        recorder override: TelemetryRecorder? = nil,
    ) async throws -> StageRunner.StageOutcome {
        try await ReviewDiarizationStage.run(
            meetingID: meetingID,
            stateStore: store,
            stageRunner: runner,
            telemetryRecorder: override ?? recorder,
            reviewer: reviewer,
            settings: settings,
        )
    }

    func readSuggestions() throws -> AIReviewerResult<DiarizationSuggestion> {
        try JSONDecoder().decode(AIReviewerResult<DiarizationSuggestion>.self, from: Data(contentsOf: url("diarization_suggestions.json")))
    }

    func events() async throws -> [StageEvent] {
        try await store.fetchStageEvents(meetingID: meetingID.rawValue).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    func state() async throws -> String? {
        try await store.fetchMeeting(id: meetingID.rawValue)?.state
    }

    func telemetry() async throws -> State.Telemetry? {
        try await store.fetchTelemetry(meetingID: meetingID.rawValue)
    }
}

func metadataObject(_ event: StageEvent) throws -> [String: Any] {
    let json = try #require(event.metadataJSON)
    return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}
