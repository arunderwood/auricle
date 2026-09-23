@testable import Attribute
import Core
import DiarizerInterface
import Foundation
import Testing

/// Holds every sleeper until `release()`, and wakes a cancelled one with
/// `CancellationError`, so a test controls exactly when the debounce elapses.
actor ManualSleeper {
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextID = 0
    private(set) var started = 0
    private(set) var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        let id = nextID
        nextID += 1
        started += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func release() {
        let all = waiters
        waiters = [:]
        for continuation in all.values {
            continuation.resume()
        }
    }
}

/// Collects the drafts a view model writes.
final class WriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [AttributionFile] = []
    var writes: [AttributionFile] {
        lock.withLock { files }
    }

    func append(_ file: AttributionFile) {
        lock.withLock { files.append(file) }
    }
}

private func attendee(_ name: String?, isSelf: Bool = false) -> CalendarAttendeeArtifact {
    CalendarAttendeeArtifact(displayName: name, isSelf: isSelf)
}

private func calendar(title: String = "Weekly sync", attendees: [CalendarAttendeeArtifact]) -> CalendarArtifact {
    let event = CalendarEventArtifact(eventID: "google:1", title: title, start: "2026-04-28T12:00:00Z", end: "2026-04-28T13:00:00Z", attendees: attendees)
    return CalendarArtifact(degraded: false, event: event)
}

@MainActor
private func makeModel(
    inputs: AttributionInputs = AttributionInputs(diarization: threeSpeakerDiarization),
    configuredSelfWikilink: String? = nil,
    glossary: Glossary = Glossary(),
    previous: any PreviousLabelings = NoPreviousLabelings(),
    sleeper: ManualSleeper = ManualSleeper(),
    log: WriteLog = WriteLog(),
) -> AttributionViewModel {
    AttributionViewModel(
        meetingID: MeetingID.generate(), inputs: inputs, configuredSelfWikilink: configuredSelfWikilink,
        glossary: glossary, previous: previous,
        sleep: { try await sleeper.sleep($0) },
        writer: { log.append($0) },
    )
}

private struct FixedLabelings: PreviousLabelings {
    var names: [String] = []
    var maps: [[String: String]] = []
    func previousNames() -> [String] {
        names
    }

    func speakerMaps(inSeries _: String) -> [[String: String]] {
        maps
    }
}

@MainActor @Test func autocompleteListsCalendarThenVaultThenPreviousEachOnce() {
    let inputs = AttributionInputs(
        diarization: threeSpeakerDiarization,
        calendar: calendar(attendees: [attendee("Sara", isSelf: true), attendee(nil), attendee("Ben")]),
    )
    let model = makeModel(
        inputs: inputs,
        glossary: Glossary(people: ["ben", "Kim"]),
        previous: FixedLabelings(names: ["KIM", "Zed", "sara"]),
    )
    #expect(model.knownNames == ["Sara", "Ben", "Kim", "Zed"])
    #expect(model.autocomplete(prefix: "k") == ["Kim"])
    #expect(model.autocomplete(prefix: "") == model.knownNames)
}

@MainActor @Test func thisIsMePicksTheLongestSpeakerAndTheCalendarSelf() {
    let inputs = AttributionInputs(diarization: threeSpeakerDiarization, calendar: calendar(attendees: [attendee("Ben"), attendee("Sara", isSelf: true)]))
    let model = makeModel(inputs: inputs)
    #expect(model.suggestedSelfSpeaker == "Speaker_2")
    #expect(model.selfName == "Sara")
    model.markThisIsMe()
    #expect(model.name(forSpeaker: "Speaker_2") == "Sara")
    #expect(model.name(forSpeaker: "Speaker_1") == nil)
}

@MainActor @Test func aConfiguredSelfWikilinkBeatsTheCalendarSelf() {
    let inputs = AttributionInputs(diarization: threeSpeakerDiarization, calendar: calendar(attendees: [attendee("Ben"), attendee("Sara", isSelf: true)]))
    let model = makeModel(inputs: inputs, configuredSelfWikilink: "[[Me]]")
    #expect(model.selfName == "Me")
    model.markThisIsMe()
    #expect(model.name(forSpeaker: "Speaker_2") == "Me")
}

@MainActor @Test func withoutAConfiguredSelfWikilinkTheCalendarSelfStands() {
    let inputs = AttributionInputs(diarization: threeSpeakerDiarization, calendar: calendar(attendees: [attendee("Ben"), attendee("Sara", isSelf: true)]))
    let model = makeModel(inputs: inputs, configuredSelfWikilink: nil)
    #expect(model.selfName == "Sara")
}

@MainActor @Test func thisIsMeDoesNothingWithoutACalendarSelf() {
    let model = makeModel()
    model.markThisIsMe()
    #expect(!model.hasUnsavedChanges)
}

@MainActor @Test func namingUsesTheGlossarySpellingOrPlainBrackets() {
    let model = makeModel(glossary: Glossary(people: ["Jordan Whitfield"]))
    model.setName("jordan whitfield", forSpeaker: "Speaker_1")
    model.setName("Newcomer", forSpeaker: "Speaker_2")
    #expect(model.draft.speakers["Speaker_1"] == "[[Jordan Whitfield]]")
    #expect(model.draft.speakers["Speaker_2"] == "[[Newcomer]]")
    model.setName("  ", forSpeaker: "Speaker_1")
    #expect(model.draft.speakers["Speaker_1"] == "Speaker_1")
    model.setName("Ghost", forSpeaker: "Speaker_9")
    #expect(model.draft.speakers["Speaker_9"] == nil)
}

@MainActor @Test func aMeetingWithoutSuggestionsHasNone() {
    #expect(makeModel().suggestions.isEmpty)
}

@MainActor @Test func aNameNeedsThreePriorMeetingsInTheSameLabelToBeProposed() {
    let two = FixedLabelings(maps: Array(repeating: ["Speaker_1": "[[Ben]]"], count: 2))
    let three = FixedLabelings(maps: Array(repeating: ["Speaker_1": "[[Ben]]", "Speaker_2": "[[Ben]]"], count: 3) + [["Speaker_3": "Speaker_3"]])
    let inputs = AttributionInputs(diarization: threeSpeakerDiarization, calendar: calendar(attendees: []))

    #expect(makeModel(inputs: inputs, previous: two).recurringPrefill.isEmpty)

    let model = makeModel(inputs: inputs, previous: three)
    #expect(model.recurringPrefill == ["Speaker_1": "Ben", "Speaker_2": "Ben"])
    #expect(model.name(forSpeaker: "Speaker_1") == nil)
    model.applyRecurringPrefill()
    #expect(model.name(forSpeaker: "Speaker_1") == "Ben")
}

@MainActor @Test func withoutACalendarTitleThereIsNoPrefill() {
    let three = FixedLabelings(maps: Array(repeating: ["Speaker_1": "[[Ben]]"], count: 3))
    #expect(makeModel(previous: three).recurringPrefill.isEmpty)
}

@MainActor @Test func overridesAndSplitsAreReplacedNotDuplicated() {
    let model = makeModel()
    model.setOverride(segmentID: "seg_1", name: "Zed")
    model.setOverride(segmentID: "seg_1", name: "Kim")
    model.setOverride(segmentID: "seg_404", name: "Nobody")
    #expect(model.draft.segmentOverrides == [SegmentOverride(segmentId: "seg_1", speaker: "[[Kim]]")])
    model.clearOverride(segmentID: "seg_1")
    #expect(model.draft.segmentOverrides.isEmpty)

    let split = SegmentSplit(originalSegmentId: "seg_2", source: .manual, splits: [
        SplitPart(newId: "seg_2.0", start: 5, end: 10, speaker: "[[A]]"),
        SplitPart(newId: "seg_2.1", start: 10, end: 25, speaker: "[[B]]"),
    ])
    model.setSplit(split)
    model.setSplit(split)
    model.setSplit(SegmentSplit(originalSegmentId: "seg_2", source: .manual, splits: [split.splits[0]]))
    #expect(model.draft.segmentSplits == [split])
    model.removeSplit(originalSegmentID: "seg_2")
    #expect(model.draft.segmentSplits.isEmpty)
}

@MainActor @Test func threeRapidEditsWriteOnceWithTheLastDraft() async {
    let sleeper = ManualSleeper()
    let log = WriteLog()
    let model = makeModel(sleeper: sleeper, log: log)

    model.setName("Ben", forSpeaker: "Speaker_1")
    model.setName("Sara", forSpeaker: "Speaker_1")
    model.setName("Kim", forSpeaker: "Speaker_1")
    await Task.yield()
    await sleeper.release()
    while model.hasUnsavedChanges {
        await Task.yield()
    }

    await model.flush()
    for _ in 0 ..< 20 {
        await Task.yield()
    }

    #expect(await sleeper.durations == Array(repeating: AttributionViewModel.debounce, count: 3))
    #expect(log.writes.count == 1)
    #expect(log.writes.first?.speakers["Speaker_1"] == "[[Kim]]")
    #expect(log.writes.first == model.draft)
}

@MainActor @Test func nothingIsWrittenBeforeTheDebounceElapses() async {
    let log = WriteLog()
    let model = makeModel(log: log)
    model.setName("Ben", forSpeaker: "Speaker_1")
    await Task.yield()
    #expect(log.writes.isEmpty)
    #expect(model.hasUnsavedChanges)
    await model.flush()
}

@MainActor @Test func flushWritesTheLatestDraftAndCancelsTheTimer() async {
    let sleeper = ManualSleeper()
    let log = WriteLog()
    let model = makeModel(sleeper: sleeper, log: log)

    model.setName("Ben", forSpeaker: "Speaker_1")
    model.setName("Sara", forSpeaker: "Speaker_2")
    await model.flush()

    #expect(log.writes == [model.draft])
    #expect(!model.hasUnsavedChanges)
    await sleeper.release()
    await Task.yield()
    #expect(log.writes.count == 1)
    await model.flush()
    #expect(log.writes.count == 1)
}

@MainActor @Test func aFailedWriteKeepsTheDraftDirtyAndReportsTheErrorType() async {
    struct Boom: Error {}
    let model = AttributionViewModel(
        meetingID: MeetingID.generate(), inputs: AttributionInputs(diarization: threeSpeakerDiarization),
        sleep: { try await ManualSleeper().sleep($0) }, writer: { _ in throw Boom() },
    )
    model.setName("Ben", forSpeaker: "Speaker_1")
    await model.flush()
    #expect(model.hasUnsavedChanges)
    #expect(model.lastWriteError?.contains("Boom") == true)
}

@MainActor @Test func aFlushedDraftIsOnDiskAndReadsBack() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    let model = try AttributionViewModel(meetingID: fixture.meetingID, inputs: AttributionInputs.load(for: fixture.meetingID))

    model.setName("Ben", forSpeaker: "Speaker_1")
    model.setOverride(segmentID: "seg_3", name: "Sara")
    await model.flush()

    #expect(try fixture.readAttribution() == model.draft)
    let reopened = try AttributionInputs.load(for: fixture.meetingID)
    #expect(reopened.existing == model.draft)
}

@Test func missingOrEmptySuggestionsLoadAsNone() async throws {
    let fixture = try await AttributeFixture()
    defer { fixture.cleanUp() }
    try fixture.plantInputs()
    #expect(try AttributionInputs.load(for: fixture.meetingID).suggestions.isEmpty)
    try AtomicWriter.write(Data("{}".utf8), to: fixture.url("diarization_suggestions.json"))
    #expect(try AttributionInputs.load(for: fixture.meetingID).suggestions.isEmpty)
}

@Test func cachedLabelingsReadPriorMeetingsAndSkipTheCurrentOne() throws {
    let current = MeetingID.generate()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("labelings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func plant(_ id: String, speakers: [String: String], title: String?) throws {
        let directory = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicWriter.write(JSONEncoder().encode(AttributionFile(speakers: speakers)), to: directory.appendingPathComponent("attribution.json"))
        if let title {
            try AtomicWriter.write(JSONEncoder().encode(calendar(title: title, attendees: [])), to: directory.appendingPathComponent("calendar.json"))
        }
    }
    try plant("A", speakers: ["Speaker_1": "[[Ben]]", "Speaker_2": "Speaker_2"], title: "Weekly Sync ")
    try plant("B", speakers: ["Speaker_1": "[[ben]]", "Speaker_2": "[[Sara]]"], title: "weekly sync")
    try plant("C", speakers: ["Speaker_1": "[[Other]]"], title: "Other meeting")
    try plant(current.rawValue, speakers: ["Speaker_1": "[[Me]]"], title: "weekly sync")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("junk"), withIntermediateDirectories: true)
    try AtomicWriter.write(Data("not json".utf8), to: root.appendingPathComponent("junk/attribution.json"))

    let labelings = CachedAttributionLabelings(cacheRoot: root, excluding: current)
    let everything = CachedAttributionLabelings(cacheRoot: root, excluding: nil)

    #expect(Set(labelings.previousNames().map { $0.lowercased() }) == ["ben", "sara", "other"])
    #expect(labelings.speakerMaps(inSeries: "Weekly Sync").count == 2)
    #expect(everything.speakerMaps(inSeries: "  WEEKLY SYNC").count == 3)
    #expect(labelings.speakerMaps(inSeries: "").isEmpty)
}
