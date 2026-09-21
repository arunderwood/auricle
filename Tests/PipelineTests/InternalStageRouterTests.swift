import AIReviewerInterface
import ArgumentParser
import Core
import Foundation
import GRDB
import Orchestrator
import Pipeline
import ReviewDiarization
@testable import State
@testable import Summarize
import SummarizerInterface
import Testing
import Transcribe
import TranscriberInterface

private struct UnreachableTranscriber: TranscriberStrategy {
    func transcribe(audio _: URL, config _: TranscriberConfig) async throws -> CanonicalTranscript {
        throw CancellationError()
    }
}

private struct UnreachableReviewer: DiarizationReviewerStrategy {
    func review(input _: DiarizationReviewInput, config _: AIReviewerConfig) async throws -> AIReviewerResult<DiarizationSuggestion> {
        throw CancellationError()
    }
}

private struct FailingSummarizer: SummarizerStrategy {
    func summarize(transcript _: CanonicalTranscript, glossary _: Glossary, config _: SummarizerConfig) async throws -> SummaryWithGrounding {
        throw SummarizerError.networkTimeout
    }
}

private struct StoreUnavailable: Error {}

private let transcriptText = "Speaker_1: we should follow up."

/// Records which stage's dependencies the router asked for and the vault path
/// it handed the summarize factory.
private final class Probe: Sendable {
    let built = Locked<[InternalStageKind]>([])
    let vaultPath = Locked<String?>(nil)

    func environment(store: @escaping () throws -> StateStore) -> InternalStageRouter.Environment {
        InternalStageRouter.Environment(
            openStateStore: store,
            transcribe: {
                self.built.value.append(.transcribe)
                return .init(transcriber: UnreachableTranscriber(), config: TranscriberConfig(), diarize: nil, ensureModel: {})
            },
            reviewDiarization: {
                self.built.value.append(.reviewDiarization)
                return .init(reviewer: UnreachableReviewer(), settings: ReviewDiarizationSettings())
            },
            summarize: { vaultPath in
                self.built.value.append(.summarize)
                self.vaultPath.value = vaultPath
                return .init(
                    orchestrator: SummarizerOrchestrator(primary: FailingSummarizer(), fallback: FailingSummarizer()),
                    glossary: Glossary(),
                    config: SummarizerConfig(),
                    calendarSource: nil,
                )
            },
        )
    }
}

private func parse(_ arguments: InternalStageArguments) throws -> InternalStageArguments {
    try InternalStageArguments.parse(Array(arguments.arguments.dropFirst()))
}

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

@Test(arguments: InternalStageKind.allCases)
func anArgumentVectorRunsOnlyItsOwnStageWorker(kind: InternalStageKind) async throws {
    let probe = Probe()
    let store = try makeStore()
    let arguments = try parse(InternalStageArguments(
        stage: kind.stage.rawValue,
        id: MeetingID.generate().rawValue,
        workerProtocolVersion: WorkerProtocolVersion.current,
    ))

    let exit = await InternalStageRouter.run(arguments, environment: probe.environment(store: { store }))

    #expect(probe.built.value == [kind])
    #expect(exit.code == WorkerExitCode.meetingNotFound)
}

@Test func aWorkerMessageCarriesTheCommandNamePrefix() async throws {
    let store = try makeStore()
    let arguments = try parse(InternalStageArguments(
        stage: "summarize",
        id: MeetingID.generate().rawValue,
        workerProtocolVersion: WorkerProtocolVersion.current,
    ))

    let exit = await InternalStageRouter.run(arguments, environment: Probe().environment(store: { store }))

    #expect(exit == WorkerExitStatus(code: WorkerExitCode.meetingNotFound, message: "__internal-stage: no meeting has the given ID."))
}

@Test func theVaultPathReachesTheSummarizeDependencies() async throws {
    let probe = Probe()
    let store = try makeStore()
    let arguments = try parse(InternalStageArguments(
        stage: "summarize",
        id: MeetingID.generate().rawValue,
        workerProtocolVersion: WorkerProtocolVersion.current,
        vaultPath: "~/vault",
    ))

    _ = await InternalStageRouter.run(arguments, environment: probe.environment(store: { store }))

    #expect(probe.vaultPath.value == "~/vault")
}

@Test(arguments: [false, true])
func publishAnywayReachesTheSummarizeWorker(publishAnyway: Bool) async throws {
    let store = try makeStore()
    let meetingID = MeetingID.generate()
    try await store.insertMeeting(Meeting(
        id: meetingID.rawValue,
        state: "attributing",
        createdAt: "2026-04-28T09:00:00Z",
        updatedAt: "2026-04-28T09:00:00Z",
        captureStartedAt: "2026-04-28T12:00:00Z",
    ))
    defer { try? FileManager.default.removeItem(at: CacheArtifactWriter.cacheDirectory(for: meetingID)) }
    try CacheArtifactWriter.write(
        CanonicalTranscript(text: transcriptText, utterances: [.init(speakerLabel: "Speaker_1", start: 0, end: transcriptText.utf8.count)]),
        for: meetingID,
        named: "transcript.json",
        schemaVersion: 1,
    )
    let arguments = try parse(InternalStageArguments(
        stage: "summarize",
        id: meetingID.rawValue,
        workerProtocolVersion: WorkerProtocolVersion.current,
        publishAnyway: publishAnyway,
    ))

    let exit = await InternalStageRouter.run(arguments, environment: Probe().environment(store: { store }))

    let summaryURL = try CacheArtifactWriter.cacheDirectory(for: meetingID).appendingPathComponent("summary.json")
    #expect(FileManager.default.fileExists(atPath: summaryURL.path) == publishAnyway)
    #expect(exit.code != WorkerExitCode.success || publishAnyway)
}

@Test func anInvalidCommandLineEndsBeforeTheStoreOpens() async {
    let probe = Probe()
    let opened = Locked(false)
    let environment = probe.environment(store: {
        opened.value = true
        return try makeStore()
    })
    let id = MeetingID.generate().rawValue
    let current = WorkerProtocolVersion.current

    let unknownStage = await InternalStageRouter.run(
        InternalStageArguments(stage: "bogus", id: id, workerProtocolVersion: current), environment: environment,
    )
    let badID = await InternalStageRouter.run(
        InternalStageArguments(stage: "summarize", id: "nope", workerProtocolVersion: current), environment: environment,
    )
    let mismatch = await InternalStageRouter.run(
        InternalStageArguments(stage: "summarize", id: id, workerProtocolVersion: current + 1), environment: environment,
    )

    let inProcessStage = await InternalStageRouter.run(
        InternalStageArguments(stage: "persist", id: id, workerProtocolVersion: current), environment: environment,
    )

    #expect(unknownStage.code == WorkerExitCode.callerError)
    #expect(inProcessStage == WorkerExitStatus(code: 2, message: "__internal-stage is not yet implemented."))
    #expect(badID.code == WorkerExitCode.callerError)
    #expect(mismatch.code == WorkerExitCode.stateError)
    #expect(!opened.value)
    #expect(probe.built.value.isEmpty)
}

@Test func aStoreThatWillNotOpenEndsWithTheStateErrorAndBuildsNothing() async {
    let probe = Probe()
    let arguments = InternalStageArguments(
        stage: "transcribe",
        id: MeetingID.generate().rawValue,
        workerProtocolVersion: WorkerProtocolVersion.current,
    )

    let exit = await InternalStageRouter.run(arguments, environment: probe.environment(store: { throw StoreUnavailable() }))

    #expect(exit == WorkerExitStatus(
        code: WorkerExitCode.stateError,
        message: "__internal-stage: could not open the state store (StoreUnavailable).",
    ))
    #expect(probe.built.value.isEmpty)
}
