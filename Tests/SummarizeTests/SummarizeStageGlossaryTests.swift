import Core
import Foundation
import State
@testable import Summarize
import SummarizerInterface
import Testing

/// Matches the stage transcript's "Ben" (a name part), its "café" (a spelling
/// that only folds to "cafe") and "Friday", and, through the attribution the
/// tests plant, "Priya". "zebra" and "Zed Zulu" are never mentioned.
private let fullVaultGlossary = Glossary(
    people: ["Ben Carter", "Priya Patel", "Zed Zulu"],
    projects: [],
    concepts: ["cafe", "zebra"],
    uncategorized: ["Friday"],
)

private let expectedScopedGlossary = Glossary(
    people: ["Ben Carter", "Priya Patel"],
    projects: [],
    concepts: ["cafe"],
    uncategorized: ["Friday"],
)

@Test func theSummarizerReceivesTheScopedGlossaryAndGlossaryJSONHoldsIt() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    try fixture.plantAttribution(["Speaker_1": "[[Priya]]"])
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary, glossary: fullVaultGlossary)

    #expect(SummarizeStage.exitCode(for: outcome) == 0)
    #expect(await primary.receivedGlossary == expectedScopedGlossary)

    let data = try Data(contentsOf: fixture.glossaryURL())
    #expect(try JSONDecoder().decode(Glossary.self, from: data) == expectedScopedGlossary)
    let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(raw["schema_version"] as? Int == 1)
    let permissions = try FileManager.default.attributesOfItem(atPath: fixture.glossaryURL().path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func theScopedGlossaryReachesThePromptInWikilinkForm() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    _ = try await fixture.run(primary: primary, glossary: fullVaultGlossary)

    let received = try #require(await primary.receivedGlossary)
    let prompt = try SummarizationPromptBuilder.build(transcript: makeStageTranscript(), glossary: received, attendees: [], mode: .substring)
    #expect(prompt.glossary.text.contains("[[Ben Carter]]"))
    #expect(prompt.glossary.text.contains("[[cafe]]"))
    #expect(!prompt.glossary.text.contains("zebra"))
}

@Test func anEmptyGlossaryStillWritesAnEmptyGlossaryJSON() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()

    _ = try await fixture.run(primary: StageStubStrategy(.success(makeStageGrounded())))

    let data = try Data(contentsOf: fixture.glossaryURL())
    #expect(try JSONDecoder().decode(Glossary.self, from: data) == Glossary())
}

@Test func glossaryJSONIsWrittenBeforeTheSummarizerIsCalled() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.failure(SummarizerError.quotaExceeded))

    let outcome = try await fixture.run(primary: primary, glossary: fullVaultGlossary)

    #expect(SummarizeStage.exitCode(for: outcome) == 2)
    #expect(await primary.callCount == 1)
    let data = try Data(contentsOf: fixture.glossaryURL())
    #expect(try JSONDecoder().decode(Glossary.self, from: data).uncategorized == ["Friday"])
}

@Test func aFailedGlossaryJSONWriteNeverFailsTheStage() async throws {
    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    try fixture.plantAttribution(["Speaker_1": "[[Priya]]"])
    try FileManager.default.createDirectory(at: fixture.glossaryURL(), withIntermediateDirectories: true)
    let primary = StageStubStrategy(.success(makeStageGrounded()))

    let outcome = try await fixture.run(primary: primary, glossary: fullVaultGlossary)

    #expect(SummarizeStage.exitCode(for: outcome) == 0)
    #expect(await primary.receivedGlossary == expectedScopedGlossary)
    #expect(try FileManager.default.fileExists(atPath: fixture.summaryURL().path))
}
