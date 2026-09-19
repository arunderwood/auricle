import Core
import Foundation
@testable import Summarize
import Testing

/// A throwaway cache root holding one directory per meeting, the shape
/// `CacheArtifactWriter` gives the real one. Files go in through
/// `AtomicWriter`, so the fixture writes what the stages write.
private struct CacheRootFixture {
    let root: URL
    let now = Date()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("auricle-wedge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func plant(_ value: some Encodable, named name: String, in directory: URL) throws {
        try AtomicWriter.write(JSONEncoder().encode(value), to: directory.appendingPathComponent(name))
    }

    /// `corrected: true` gives a summary that spells the glossary's term
    /// where the transcript heard "mesh core".
    @discardableResult
    func plantMeeting(
        _ id: String,
        corrected: Bool,
        actionItemText: String? = nil,
        decisionText: String? = nil,
        glossary: Glossary? = Glossary(concepts: ["meshcore"]),
        summaryAge: TimeInterval = 86400,
        transcriptJSON: String? = nil,
    ) throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let summary = SummaryArtifact(
            title: "Meeting",
            calendarEventTitle: nil,
            attendees: [],
            selfWikilink: nil,
            needsAttribution: false,
            needsCalendarEnrichment: true,
            summary: corrected ? "Rolled out [[meshcore]] this week." : "Rolled out the radios this week.",
            actionItems: actionItemText.map { [QuotedItemArtifact(text: $0, quote: "q")] } ?? [],
            decisions: decisionText.map { [QuotedItemArtifact(text: $0, quote: "q")] } ?? [],
            transcriptSegments: [],
        )
        try plant(summary, named: "summary.json", in: directory)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-summaryAge)],
            ofItemAtPath: directory.appendingPathComponent("summary.json").path,
        )

        if let transcriptJSON {
            try AtomicWriter.write(Data(transcriptJSON.utf8), to: directory.appendingPathComponent("transcript.json"))
        } else {
            try plant(CanonicalTranscript(text: "Speaker_1: we rolled out mesh core and radios", utterances: []), named: "transcript.json", in: directory)
        }
        if let glossary {
            try plant(glossary, named: "glossary.json", in: directory)
        }
        return directory
    }
}

@Test func twoOfFiveMeetingsWithACorrectionMeetTheCriterion() throws {
    let fixture = try CacheRootFixture()
    defer { fixture.cleanUp() }
    try fixture.plantMeeting("m1", corrected: true)
    try fixture.plantMeeting("m2", corrected: true)
    try fixture.plantMeeting("m3", corrected: false)
    try fixture.plantMeeting("m4", corrected: false)
    try fixture.plantMeeting("m5", corrected: false)

    let report = JargonWedgeMeasurement.measure(cacheRoot: fixture.root, now: fixture.now)

    #expect(report.eligibleMeetings == 5)
    #expect(report.meetingsWithCorrection == 2)
    #expect(report.missingArtifactMeetings == 0)
    #expect(report.rate == 0.4)
    #expect(report.meetsCriterion)
    #expect(report.windowDays == 30)
}

@Test func oneOfFiveMeetingsWithACorrectionMissesTheCriterion() throws {
    let fixture = try CacheRootFixture()
    defer { fixture.cleanUp() }
    try fixture.plantMeeting("m1", corrected: true)
    for id in ["m2", "m3", "m4", "m5"] {
        try fixture.plantMeeting(id, corrected: false)
    }

    let report = JargonWedgeMeasurement.measure(cacheRoot: fixture.root, now: fixture.now)

    #expect(report.rate == 0.2)
    #expect(!report.meetsCriterion)
}

@Test func aMeetingMissingAnArtifactCountsAsMissingAndStaysOutOfTheRate() throws {
    let fixture = try CacheRootFixture()
    defer { fixture.cleanUp() }
    try fixture.plantMeeting("m1", corrected: true)
    try fixture.plantMeeting("m2", corrected: false)
    try fixture.plantMeeting("no-glossary", corrected: true, glossary: nil)

    let report = JargonWedgeMeasurement.measure(cacheRoot: fixture.root, now: fixture.now)

    #expect(report.eligibleMeetings == 2)
    #expect(report.meetingsWithCorrection == 1)
    #expect(report.missingArtifactMeetings == 1)
    #expect(report.rate == 0.5)
}

@Test func anUnreadableArtifactCountsAsMissing() throws {
    let fixture = try CacheRootFixture()
    defer { fixture.cleanUp() }
    try fixture.plantMeeting("garbled", corrected: true, transcriptJSON: "{ not a transcript")

    let report = JargonWedgeMeasurement.measure(cacheRoot: fixture.root, now: fixture.now)

    #expect(report.eligibleMeetings == 0)
    #expect(report.missingArtifactMeetings == 1)
    #expect(report.rate == nil)
    #expect(!report.meetsCriterion)
}

@Test func noEligibleMeetingsGivesNoRateAndAnUnmetCriterion() throws {
    let fixture = try CacheRootFixture()
    defer { fixture.cleanUp() }

    let empty = JargonWedgeMeasurement.measure(cacheRoot: fixture.root, now: fixture.now)
    let absent = JargonWedgeMeasurement.measure(cacheRoot: fixture.root.appendingPathComponent("nope"), now: fixture.now)

    for report in [empty, absent] {
        #expect(report.eligibleMeetings == 0)
        #expect(report.meetingsWithCorrection == 0)
        #expect(report.missingArtifactMeetings == 0)
        #expect(report.rate == nil)
        #expect(!report.meetsCriterion)
    }
}

@Test func onlyMeetingsWhoseSummaryWasWrittenInsideTheWindowCount() throws {
    let fixture = try CacheRootFixture()
    defer { fixture.cleanUp() }
    try fixture.plantMeeting("recent", corrected: true, summaryAge: 29 * 86400)
    try fixture.plantMeeting("old", corrected: true, summaryAge: 31 * 86400)
    try fixture.plantMeeting("old-and-incomplete", corrected: true, glossary: nil, summaryAge: 40 * 86400)

    let report = JargonWedgeMeasurement.measure(cacheRoot: fixture.root, now: fixture.now)

    #expect(report.eligibleMeetings == 1)
    #expect(report.missingArtifactMeetings == 0)
}

@Test func aDirectoryWithoutASummaryAndLooseFilesAreNotMeetings() throws {
    let fixture = try CacheRootFixture()
    defer { fixture.cleanUp() }
    let unfinished = fixture.root.appendingPathComponent("unfinished", isDirectory: true)
    try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
    try AtomicWriter.write(Data("{}".utf8), to: unfinished.appendingPathComponent("transcript.json"))
    try AtomicWriter.write(Data("{}".utf8), to: fixture.root.appendingPathComponent("glossary-cache.json"))

    let report = JargonWedgeMeasurement.measure(cacheRoot: fixture.root, now: fixture.now)

    #expect(report.eligibleMeetings == 0)
    #expect(report.missingArtifactMeetings == 0)
}

@Test func aCorrectedTermInAnActionItemCounts() throws {
    let fixture = try CacheRootFixture()
    defer { fixture.cleanUp() }
    try fixture.plantMeeting("m1", corrected: false, actionItemText: "Order more [[meshcore]] nodes")

    let report = JargonWedgeMeasurement.measure(cacheRoot: fixture.root, now: fixture.now)

    #expect(report.meetingsWithCorrection == 1)
}

@Test func aCorrectedTermInADecisionCounts() throws {
    let fixture = try CacheRootFixture()
    defer { fixture.cleanUp() }
    try fixture.plantMeeting("m1", corrected: false, decisionText: "Adopt [[meshcore]] for the roof nodes")

    let report = JargonWedgeMeasurement.measure(cacheRoot: fixture.root, now: fixture.now)

    #expect(report.meetingsWithCorrection == 1)
}
