import Core
import Foundation
@testable import Summarize
import Testing

/// The canned fixture every test in this file builds from — inline Swift
/// values, not a separate fixture file, since the whole point is that this
/// exact `(transcript, glossary, attendees)` triple is what the checked-in
/// snapshots below were generated against.
private func makeTranscript() -> CanonicalTranscript {
    CanonicalTranscript(
        text: "Ben: I'll take a first pass at the brief by Friday.\nPriya: Let's push the launch to the 15th.",
        utterances: [
            CanonicalTranscript.Utterance(speakerLabel: "Ben", start: 0, end: 51),
            CanonicalTranscript.Utterance(speakerLabel: "Priya", start: 52, end: 93),
        ],
    )
}

private func makeGlossary() -> Glossary {
    Glossary(
        people: ["Ben", "Priya Patel"],
        projects: ["chicken-palace"],
        concepts: ["meshcore"],
    )
}

private let attendees = ["Ben", "Priya Patel"]

private func makeTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A `Bundle` guaranteed to carry none of `Prompts/summarize/`'s files —
/// stands in for the shipped bundle being missing a resource (a packaging
/// defect this test can't reproduce by actually corrupting the real bundle).
/// Returns the backing directory too, so the caller can clean it up the same
/// way every other test in this file does for its own `makeTestDirectory()`.
private func makeEmptyBundle() -> (bundle: Bundle, directory: URL) {
    let directory = makeTestDirectory()
    // A freshly created directory always resolves to a `Bundle` — the
    // force-unwrap documents that this can't fail, the same way
    // `MeetingID(ulid:)!` does elsewhere in this test suite for an
    // input already known to be well-formed.
    return (Bundle(path: directory.path)!, directory)
}

/// A `Bundle` whose `Prompts/summarize/<fileName>` resource exists but isn't
/// valid UTF-8 — stands in for a corrupted bundled resource. Returns the
/// backing directory for cleanup, same as `makeEmptyBundle()`.
private func makeBundleWithInvalidUTF8Resource(named fileName: String) throws -> (bundle: Bundle, directory: URL) {
    let directory = makeTestDirectory()
    let resourceDirectory = directory.appendingPathComponent("Prompts/summarize")
    try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0x80, 0x81]).write(to: resourceDirectory.appendingPathComponent(fileName))
    return (Bundle(path: directory.path)!, directory)
}

/// Reconstructs the composed output as one comparable string, in a fixed
/// block order, for the snapshot files under `Snapshots/prompts/`.
private func snapshotText(for prompt: SummarizationPrompt) -> String {
    [
        "=== system ===",
        prompt.system.text,
        "",
        "=== glossary ===",
        prompt.glossary.text,
        "",
        "=== attendeeContext ===",
        prompt.attendeeContext.text,
        "",
        "=== transcript ===",
        prompt.transcript.text,
    ].joined(separator: "\n")
}

private func loadGolden(_ fileName: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: fileName, withExtension: "txt", subdirectory: "Snapshots/prompts"))
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - Snapshot tests (bundled default set only)

@Test func citationsModeMatchesCheckedInSnapshot() throws {
    let prompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(),
        glossary: makeGlossary(),
        attendees: attendees,
        mode: .citations,
    )

    let golden = try loadGolden("citations")
    #expect(snapshotText(for: prompt) == golden)
}

@Test func substringModeMatchesCheckedInSnapshot() throws {
    let prompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(),
        glossary: makeGlossary(),
        attendees: attendees,
        mode: .substring,
    )

    let golden = try loadGolden("substring")
    #expect(snapshotText(for: prompt) == golden)
}

// MARK: - Mode drift

@Test func sharedBlocksAreByteIdenticalAcrossModesAndOnlyTheAddendumDiffers() throws {
    let citationsAddendum = """
    Use Anthropic Citations to ground each item. Cite the document for each item.

    Each action item and decision must also include a `source_block_index` field: the zero-indexed transcript content block that grounds it.
    """
    let substringAddendum = """
    Each item must include a `source_transcript_quote` field reproducing the exact transcript text, \
    character-for-character including punctuation. Do not normalize, expand contractions, or remove disfluencies.
    """

    let citationsPrompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations,
    )
    let substringPrompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .substring,
    )

    #expect(citationsPrompt.glossary == substringPrompt.glossary)
    #expect(citationsPrompt.attendeeContext == substringPrompt.attendeeContext)
    #expect(citationsPrompt.transcript == substringPrompt.transcript)

    #expect(citationsPrompt.system.text.hasSuffix(citationsAddendum))
    #expect(substringPrompt.system.text.hasSuffix(substringAddendum))
    let citationsShared = citationsPrompt.system.text.dropLast(citationsAddendum.count + 2)
    let substringShared = substringPrompt.system.text.dropLast(substringAddendum.count + 2)
    #expect(citationsShared == substringShared)

    #expect(citationsPrompt.promptSetHash != substringPrompt.promptSetHash)
}

// MARK: - Prompt caching

@Test func onlyTheTranscriptBlockIsMarkedNonCacheable() throws {
    let prompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations,
    )

    #expect(prompt.system.cacheable == true)
    #expect(prompt.glossary.cacheable == true)
    #expect(prompt.attendeeContext.cacheable == true)
    #expect(prompt.transcript.cacheable == false)
}

// MARK: - File resolution

@Test func defaultResolutionUsesTheBundledSetForBothFiles() throws {
    let prompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations, promptDir: nil,
    )
    #expect(prompt.promptSetHash.count == 64)
    #expect(prompt.promptSetHash == prompt.promptSetHash.lowercased())
}

@Test func partialOverrideFallsBackToBundledForTheMissingFile() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let overriddenSystem = "OVERRIDDEN SYSTEM PROMPT"
    try overriddenSystem.write(to: directory.appendingPathComponent("system.md"), atomically: true, encoding: .utf8)

    let prompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations, promptDir: directory,
    )

    #expect(prompt.system.text.hasPrefix(overriddenSystem))
    #expect(prompt.system.text.contains("Use Anthropic Citations to ground each item. Cite the document for each item."))
    #expect(prompt.system.text.hasSuffix(
        "Each action item and decision must also include a `source_block_index` field: the zero-indexed transcript content block that grounds it.",
    ))
}

@Test func missingBundledResourceThrows() throws {
    let (bundle, directory) = makeEmptyBundle()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: SummarizationPromptBuilderError.bundledPromptResourceMissing(file: "system.md")) {
        try SummarizationPromptBuilder.build(
            transcript: makeTranscript(),
            glossary: makeGlossary(),
            attendees: attendees,
            mode: .citations,
            promptDir: nil,
            bundle: bundle,
        )
    }
}

@Test func bundledResourceWithInvalidUTF8Throws() throws {
    let (bundle, directory) = try makeBundleWithInvalidUTF8Resource(named: "system.md")
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: SummarizationPromptBuilderError.bundledPromptResourceMissing(file: "system.md")) {
        try SummarizationPromptBuilder.build(
            transcript: makeTranscript(),
            glossary: makeGlossary(),
            attendees: attendees,
            mode: .citations,
            promptDir: nil,
            bundle: bundle,
        )
    }
}

@Test func unreadableOverrideFileThrows() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let invalidUTF8 = Data([0xFF, 0xFE, 0x80, 0x81])
    try invalidUTF8.write(to: directory.appendingPathComponent("system.md"))

    #expect(throws: SummarizationPromptBuilderError.overridePromptFileUnreadable(file: "system.md")) {
        try SummarizationPromptBuilder.build(
            transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations, promptDir: directory,
        )
    }
}

@Test func emptyOverrideFileThrows() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try "   \n\n  ".write(to: directory.appendingPathComponent("system.md"), atomically: true, encoding: .utf8)

    #expect(throws: SummarizationPromptBuilderError.overridePromptFileUnreadable(file: "system.md")) {
        try SummarizationPromptBuilder.build(
            transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations, promptDir: directory,
        )
    }
}

@Test func hashChangesWhenAnOverrideFilesContentChanges() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let systemURL = directory.appendingPathComponent("system.md")

    try "First version".write(to: systemURL, atomically: true, encoding: .utf8)
    let firstHash = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations, promptDir: directory,
    ).promptSetHash

    try "Second, different version".write(to: systemURL, atomically: true, encoding: .utf8)
    let secondHash = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations, promptDir: directory,
    ).promptSetHash

    #expect(firstHash != secondHash)
}

/// Guards against a regression that hashes the trimmed/composed display
/// text instead of the raw file bytes `promptSetHash`'s contract requires:
/// two override files differing only by trailing whitespace produce the
/// same *displayed* system text (`resolvedText` trims it away) but must
/// still hash differently, since the hash reflects exactly what was read.
@Test func hashDiffersForOverrideFilesThatDifferOnlyByTrailingWhitespace() throws {
    let directoryWithoutTrailingBlankLine = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directoryWithoutTrailingBlankLine) }
    try "System prompt content".write(
        to: directoryWithoutTrailingBlankLine.appendingPathComponent("system.md"), atomically: true, encoding: .utf8,
    )

    let directoryWithTrailingBlankLine = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directoryWithTrailingBlankLine) }
    try "System prompt content\n\n".write(
        to: directoryWithTrailingBlankLine.appendingPathComponent("system.md"), atomically: true, encoding: .utf8,
    )

    let hashWithoutTrailingBlankLine = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations,
        promptDir: directoryWithoutTrailingBlankLine,
    ).promptSetHash
    let hashWithTrailingBlankLine = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: attendees, mode: .citations,
        promptDir: directoryWithTrailingBlankLine,
    ).promptSetHash

    #expect(hashWithoutTrailingBlankLine != hashWithTrailingBlankLine)
}

// MARK: - Glossary rendering

@Test func emptyGlossaryRendersAsEmptyBlock() throws {
    let prompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: Glossary(), attendees: attendees, mode: .citations,
    )
    #expect(prompt.glossary.text == "")
}

@Test func nonStandardVaultGlossaryRendersOnlyTheUncategorizedLine() throws {
    let glossary = Glossary(uncategorized: ["misc-term"])
    let prompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: glossary, attendees: attendees, mode: .citations,
    )
    #expect(prompt.glossary.text == "Glossary (terms from your vault, prefer these spellings):\n- Uncategorized: [[misc-term]]")
}

// MARK: - Attendee rendering

@Test func noAttendeesRendersAsEmptyBlock() throws {
    let prompt = try SummarizationPromptBuilder.build(
        transcript: makeTranscript(), glossary: makeGlossary(), attendees: [], mode: .citations,
    )
    #expect(prompt.attendeeContext.text == "")
}
