@testable import Attribute
import Core
import Foundation
@testable import State
import Testing

@Test func aSpeakersFlagWritesTheMappingAndAdvancesToSummarizing() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()

    let status = await fixture.run(.batch(speakers: "1=Ben,2=Jordan Whitfield"))

    #expect(status == WorkerExitStatus(code: 0))
    let file = try fixture.readAttribution()
    #expect(file.speakers == ["Speaker_1": "[[Ben]]", "Speaker_2": "[[Jordan Whitfield]]", "Speaker_3": "Speaker_3"])
    #expect(file.segmentOverrides.isEmpty && file.segmentSplits.isEmpty)
    #expect(try await fixture.state() == "summarizing")

    let events = try await fixture.events().filter { $0.stage == "attribute" }
    #expect(events.map(\.event) == ["started", "completed"])
    let meta = try metadata(#require(events.last))
    #expect(meta["completion_path"] as? String == "cli_speakers_flag")
    #expect(meta["named_count"] as? Int == 2)
    #expect(meta["speaker_count"] as? Int == 3)
    let telemetry = try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue)
    #expect(telemetry?.attributionCompletionPath == "cli_speakers_flag")
}

@Test func theFileIsOwnerOnlyAndCarriesASchemaVersion() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try AttributionFile(speakers: ["Speaker_1": "Speaker_1"]).write(for: fixture.meetingID)

    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url(AttributionFile.fileName).path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    #expect(try fixture.rawAttribution()["schema_version"] as? Int == 1)
}

@Test func aGlossaryNameUsesTheVaultSpelling() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()

    _ = await fixture.run(.batch(speakers: "1=jordan whitfield"), glossary: Glossary(people: ["Jordan Whitfield"]))

    #expect(try fixture.readAttribution().speakers["Speaker_1"] == "[[Jordan Whitfield]]")
}

@Test func batchWithoutAFlagReusesTheExistingMap() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    try AttributionFile(speakers: ["Speaker_1": "[[Ben]]", "Speaker_2": "Speaker_2", "Speaker_3": "Speaker_3"]).write(for: fixture.meetingID)
    let before = try Data(contentsOf: fixture.url(AttributionFile.fileName))

    let status = await fixture.run(.batch(speakers: nil))

    #expect(status.code == 0)
    #expect(try Data(contentsOf: fixture.url(AttributionFile.fileName)) == before)
    #expect(try await fixture.state() == "summarizing")
}

@Test func batchWithNoMappingExitsOneAndChangesNothing() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()

    let status = await fixture.run(.batch(speakers: nil))

    #expect(status == WorkerExitStatus(code: 1, message: "no speaker mapping; run with --interactive or pass --speakers"))
    #expect(try await fixture.state() == "awaiting_attribution")
    #expect(try await fixture.events().isEmpty)
    #expect(!fixture.exists(AttributionFile.fileName))
}

@Test(arguments: ["1=Ben,1=Sara", "1=Ben,2=Ben", "7=Ben", "1="])
func aBadMappingWritesNothingAndLeavesTheState(raw: String) async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()

    let status = await fixture.run(.batch(speakers: raw))

    #expect(status.code == 1)
    #expect(status.message?.contains("--speakers") == true)
    #expect(!fixture.exists(AttributionFile.fileName))
    #expect(try await fixture.state() == "awaiting_attribution")
    #expect(try await fixture.events().isEmpty)
}

@Test func publishAnywayWritesAllPlaceholdersAndEmptyArrays() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    try AttributionFile(
        speakers: ["Speaker_1": "[[Ben]]"],
        segmentOverrides: [SegmentOverride(segmentId: "seg_1", speaker: "[[Zed]]")],
    ).write(for: fixture.meetingID)

    let status = await fixture.run(.publishAnyway)

    #expect(status.code == 0)
    let file = try fixture.readAttribution()
    #expect(file.speakers == ["Speaker_1": "Speaker_1", "Speaker_2": "Speaker_2", "Speaker_3": "Speaker_3"])
    #expect(file.segmentOverrides.isEmpty && file.segmentSplits.isEmpty)
    #expect(try await fixture.state() == "summarizing")
    let completed = try #require(await fixture.events().last { $0.event == "completed" })
    #expect(try metadata(completed)["named_count"] as? Int == 0)
    let telemetry = try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue)
    #expect(telemetry?.attributionCompletionPath == "publish_anyway")
}

@Test func aMeetingNotAwaitingAttributionIsRefused() async throws {
    let fixture = try await AttributeFixture(state: "published")
    defer { fixture.cleanUp() }
    try fixture.plantInputs()

    let status = await fixture.run(.batch(speakers: "1=Ben"))

    #expect(status.code == 1)
    #expect(try await fixture.state() == "published")
    #expect(!fixture.exists(AttributionFile.fileName))
}

@Test func anUnknownMeetingExitsThree() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    let status = await AttributionStage.execute(
        meetingID: MeetingID.generate(), mode: .publishAnyway, stateStore: fixture.store,
        stageRunner: fixture.runner, telemetryRecorder: fixture.recorder,
    )
    #expect(status.code == WorkerExitCode.meetingNotFound)
}

@Test func missingDiarizationIsRefusedBeforeAnythingIsRecorded() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }

    let status = await fixture.run(.publishAnyway)

    #expect(status.code == 1)
    #expect(try await fixture.events().isEmpty)
}

@Test func theImmutableInputsAreNeverModified() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    let planted = try fixture.plantInputs()

    _ = await fixture.run(.batch(speakers: "1=Ben"))

    #expect(try Data(contentsOf: fixture.url("transcript.json")) == planted.transcript)
    #expect(try Data(contentsOf: fixture.url("diarization.json")) == planted.diarization)
    #expect(!fixture.exists("diarization_suggestions.json"))
}

@Test func existingCorrectionsSurviveANewSpeakersMapping() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    let override = SegmentOverride(segmentId: "seg_3", speaker: "[[Zed]]")
    try AttributionFile(speakers: [:], segmentOverrides: [override]).write(for: fixture.meetingID)

    _ = await fixture.run(.batch(speakers: "1=Ben"))

    #expect(try fixture.readAttribution().segmentOverrides == [override])
}

@Test func aMeetingLeftInAttributingCanBeRetried() async throws {
    let fixture = try await AttributeFixture(state: "attributing")
    defer { fixture.cleanUp() }
    try fixture.plantInputs()

    #expect(await fixture.run(.publishAnyway).code == 0)
    #expect(try await fixture.state() == "summarizing")
}

private func metadata(_ event: StageEvent) throws -> [String: Any] {
    let json = try #require(event.metadataJSON)
    return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

@Test func aCorruptAttributionFileIsRefusedAndLeftAlone() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    try AtomicWriter.write(Data("not json".utf8), to: fixture.url(AttributionFile.fileName))
    let before = try Data(contentsOf: fixture.url(AttributionFile.fileName))

    let status = await fixture.run(.batch(speakers: "1=Ben"))

    #expect(status == WorkerExitStatus(code: 1, message: AttributionStageError.attributionUnreadable.userMessage))
    #expect(try Data(contentsOf: fixture.url(AttributionFile.fileName)) == before)
    #expect(try await fixture.state() == "awaiting_attribution")
    #expect(try await fixture.events().isEmpty)
}

@Test func aCorruptDiarizationFileIsRefusedBeforeAnythingIsRecorded() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    try AtomicWriter.write(Data("not json".utf8), to: fixture.url("diarization.json"))

    let status = await fixture.run(.batch(speakers: "1=Ben"))

    #expect(status == WorkerExitStatus(code: 1, message: AttributionStageError.diarizationUnreadable.userMessage))
    #expect(!fixture.exists(AttributionFile.fileName))
    #expect(try await fixture.state() == "awaiting_attribution")
    #expect(try await fixture.events().isEmpty)
}

@Test func aFailedWriteLeavesTheMeetingAttributingAndARetrySucceeds() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    let directory = try CacheArtifactWriter.cacheDirectory(for: fixture.meetingID)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

    let failed = await fixture.run(.batch(speakers: "1=Ben"))

    #expect(failed == WorkerExitStatus(code: WorkerExitCode.stateError, message: AttributionStageError.attributionWriteFailed.userMessage))
    #expect(try await fixture.state() == "attributing")

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    #expect(await fixture.run(.batch(speakers: "1=Ben")).code == 0)
    #expect(try fixture.readAttribution().speakers["Speaker_1"] == "[[Ben]]")
    #expect(try await fixture.state() == "summarizing")
}
