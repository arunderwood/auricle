import AIReviewerInterface
import ClaudeSummarizer
import Core
import Diarize
import DiarizerInterface
import Foundation
import Notifications
import Orchestrator
import Pipeline
import ReviewDiarization
import State
import Summarize
import SummarizerInterface
import Telemetry
import Transcribe
import TranscriberInterface

final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

final class RecordingNotifier: Notifier {
    let paths = Locked<[String]>([])
    func fire(meetingID _: MeetingID, title _: String, vaultPath: String) async {
        paths.value.append(vaultPath)
    }
}

/// One synthetic meeting: who says what, and what the stubbed model claims.
/// Every line is invented for this test; none comes from a recording.
struct Scenario: Sendable {
    struct Line: Sendable {
        let speaker: String
        let text: String
    }

    let label: String
    let lines: [Line]
    /// Quotes the stub model attaches to action items and decisions.
    let actionQuotes: [String]
    let decisionQuotes: [String]
    /// A `Speaker_N`-to-wikilink map, or `nil` to run with `--publish-anyway`.
    let speakerNames: [String: String]?

    /// The transcriber's real shape: it cannot tell speakers apart, so every
    /// utterance carries one label and only `StubDiarizer` knows who spoke.
    var transcript: CanonicalTranscript {
        CanonicalTranscriptBuilder.build(lines.map { (speakerLabel: WhisperKitTranscriberLabel.value, text: $0.text) })
    }

    /// Evenly spaced across the reference audio, so every segment lies inside it.
    func timings(audioSeconds: Double) -> [UtteranceTiming] {
        let width = audioSeconds / Double(lines.count)
        return lines.indices.map { UtteranceTiming(index: $0, startSeconds: Double($0) * width, endSeconds: Double($0 + 1) * width) }
    }
}

enum WhisperKitTranscriberLabel {
    static let value = "Speaker_1"
}

/// Stands in for WhisperKit: returns the scenario's transcript and never
/// reads the audio.
struct StubTranscriber: TranscriberStrategy {
    let scenario: Scenario
    let audioSeconds: Double

    func transcribe(audio _: URL, config _: TranscriberConfig) async throws -> CanonicalTranscript {
        scenario.transcript
    }

    func transcribeTimed(audio _: URL, config _: TranscriberConfig) async throws -> TimedTranscript {
        TimedTranscript(transcript: scenario.transcript, utteranceTimings: scenario.timings(audioSeconds: audioSeconds))
    }
}

/// Stands in for SpeakerKit: one segment per utterance, labelled as the
/// scenario says. This is the only place the speakers are told apart.
struct StubDiarizer: DiarizerStrategy {
    let scenario: Scenario

    func diarize(
        transcript _: CanonicalTranscript,
        utteranceTimings: [UtteranceTiming],
        audio _: URL,
        config _: DiarizerConfig,
    ) async throws -> DiarizationArtifact {
        let segments = zip(scenario.lines, utteranceTimings).enumerated().map { offset, pair in
            DiarizedSegment(
                id: "seg_\(offset + 1)",
                speakerLabel: pair.0.speaker,
                startSeconds: pair.1.startSeconds,
                endSeconds: pair.1.endSeconds,
                utteranceIndex: DiarizedUtteranceRange(first: offset, last: offset),
                voiceProfile: DiarizedVoiceProfile(overlapRatio: 0),
            )
        }
        return DiarizationArtifact(segments: segments)
    }
}

struct ReviewerCalled: Error {}

/// The review flag is off in these runs, so a call to the reviewer is a bug.
struct FailingReviewer: DiarizationReviewerStrategy {
    func review(input _: DiarizationReviewInput, config _: AIReviewerConfig) async throws -> AIReviewerResult<DiarizationSuggestion> {
        throw ReviewerCalled()
    }
}

/// Runs each subprocess stage's real worker in this process, so the runner is
/// exercised end to end without spawning `auricle-cli` or loading a model.
struct InProcessLauncher: StageWorkerLauncher {
    let store: StateStore
    let scenario: Scenario
    let audioSeconds: Double
    let orchestrator: SummarizerOrchestrator

    func run(stage: PipelineStage, meetingID: MeetingID, publishAnyway: Bool) async throws -> TranscribeRetryPolicy.Termination {
        let stageRunner = StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store))
        let exit: WorkerExitStatus
        switch stage {
        case .transcribe:
            let diarizer = StubDiarizer(scenario: scenario)
            exit = await TranscribeWorker.run(
                meetingID: meetingID,
                stateStore: store,
                stageRunner: stageRunner,
                transcriber: StubTranscriber(scenario: scenario, audioSeconds: audioSeconds),
                config: TranscriberConfig(),
                diarize: { input in
                    try await DiarizeStage.run(
                        meetingID: input.meetingID,
                        transcript: input.transcript,
                        utteranceTimings: input.utteranceTimings,
                        audio: input.audio,
                        diarizer: diarizer,
                        config: DiarizerConfig(),
                    )
                },
                ensureModel: {},
            )
        case .reviewDiarization:
            exit = await ReviewDiarizationWorker.run(
                meetingID: meetingID,
                stateStore: store,
                stageRunner: stageRunner,
                reviewer: FailingReviewer(),
                settings: ReviewDiarizationSettings(enabled: false),
            )
        case .summarize:
            exit = await SummarizeWorker.run(
                meetingID: meetingID,
                stateStore: store,
                orchestrator: orchestrator,
                glossary: Glossary(),
                config: SummarizerConfig(),
                calendarSource: nil,
                publishAnyway: publishAnyway,
            )
        default:
            return .exited(WorkerExitCode.callerError)
        }
        return .exited(exit.code)
    }
}

// MARK: - Anthropic stub

/// Answers every request with one fixed 200 body and counts them. The request
/// is never read, so nothing in a prompt can change the answer.
final class AnthropicStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var bodies: [URL: Data] = [:]
    private nonisolated(unsafe) static var counts: [URL: Int] = [:]

    static func register(url: URL, body: Data) {
        lock.withLock {
            bodies[url] = body
            counts[url] = 0
        }
    }

    static func unregister(url: URL) {
        lock.withLock {
            bodies[url] = nil
            counts[url] = nil
        }
    }

    static func count(for url: URL) -> Int {
        lock.withLock { counts[url] ?? 0 }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let body: Data? = Self.lock.withLock {
            Self.counts[url, default: 0] += 1
            return Self.bodies[url]
        }
        guard let body, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct AnthropicStub {
    /// Absent from every scenario transcript. The validator has to drop it.
    static let ungroundedQuote = "The board approved a lunar relocation by Tuesday."

    let client: AnthropicHTTPClient
    private let endpoint: URL

    var requestCount: Int {
        AnthropicStubProtocol.count(for: endpoint)
    }

    init(scenario: Scenario) throws {
        endpoint = URL(string: "https://anthropic-stub.invalid/\(UUID().uuidString)")!
        try AnthropicStubProtocol.register(url: endpoint, body: Self.responseBody(for: scenario))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnthropicStubProtocol.self]
        client = AnthropicHTTPClient(
            session: URLSession(configuration: configuration),
            endpoint: endpoint,
            apiKeyProvider: { "test-key" },
            sleep: { _ in },
        )
    }

    func release() {
        AnthropicStubProtocol.unregister(url: endpoint)
    }

    /// Each section holds the scenario's grounded quotes and then one item
    /// whose quote is in no transcript.
    private static func responseBody(for scenario: Scenario) throws -> Data {
        func items(_ quotes: [String], label: String) -> [[String: String]] {
            (quotes + [ungroundedQuote]).enumerated().map { ["text": "\(label) \($0.offset + 1)", "source_transcript_quote": $0.element] }
        }
        let answer: [String: Any] = [
            "summary": "A synthetic summary.",
            "action_items": items(scenario.actionQuotes, label: "Action"),
            "decisions": items(scenario.decisionQuotes, label: "Decision"),
        ]
        let answerData = try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
        guard let answerText = String(bytes: answerData, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return try JSONSerialization.data(
            withJSONObject: [
                "model": "claude-opus-5",
                "content": [["type": "text", "text": answerText]],
                "stop_reason": "end_turn",
                "usage": ["input_tokens": 100, "output_tokens": 50],
            ] as [String: Any],
            options: [.sortedKeys],
        )
    }
}
