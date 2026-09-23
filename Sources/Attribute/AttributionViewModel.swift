import AIReviewerInterface
import Core
import DiarizerInterface
import Foundation
import Observation

/// The state behind attribution, shared by the CLI and the attribution sheet
/// so one type is the contract for both. It holds the draft `attribution.json`,
/// the names to offer, and the debounced write that keeps the draft on disk.
///
/// It has no `State`, vault or `StateStore` dependency: the vault's names come
/// in as a `Glossary`, prior labelings through `PreviousLabelings`, and the
/// meeting's state stays with `AttributionStage`.
@MainActor @Observable
public final class AttributionViewModel {
    /// How long after the last edit the draft is written.
    public static let debounce: Duration = .milliseconds(500)

    /// A speaker needs a name from the same label in this many earlier
    /// meetings of a series before it is proposed.
    static let prefillThreshold = 3

    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Writer = @Sendable (AttributionFile) throws -> Void

    public let meetingID: MeetingID
    public let diarization: DiarizationArtifact
    public let suggestions: [DiarizationSuggestion]
    /// The draft as it stands, edited only through the mutation methods.
    public private(set) var draft: AttributionFile
    /// Calendar attendees, then vault people, then previously labeled names.
    public let knownNames: [String]
    /// The user's own name for "this is me": the bare name of the configured
    /// `self.wikilink` when it normalizes, else the calendar attendee marked
    /// as self, else `nil`.
    public let selfName: String?
    /// The speaker who talked longest: "this is me" starts here.
    public let suggestedSelfSpeaker: String?
    /// `Speaker_N` to a bare name held by that label in enough earlier
    /// meetings of this series. A proposal only; see `applyRecurringPrefill`.
    public let recurringPrefill: [String: String]
    /// `true` from an edit until the write that includes it succeeds.
    public private(set) var hasUnsavedChanges = false
    /// The type of the last write's error; `nil` after a successful write.
    public private(set) var lastWriteError: String?

    private let glossary: Glossary
    private let sleep: Sleep
    private let writer: Writer
    private var pendingWrite: Task<Void, Never>?
    private let log = Log(category: "attribution-view-model")

    public init(
        meetingID: MeetingID,
        inputs: AttributionInputs,
        configuredSelfWikilink: String? = nil,
        glossary: Glossary = Glossary(),
        previous: any PreviousLabelings = NoPreviousLabelings(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        writer: Writer? = nil,
    ) {
        self.meetingID = meetingID
        diarization = inputs.diarization
        suggestions = inputs.suggestions
        self.glossary = glossary
        self.sleep = sleep
        self.writer = writer ?? { try $0.write(for: meetingID) }

        let labels = inputs.diarization.speakerLabels
        var draft = inputs.existing ?? AttributionFile()
        for label in labels where draft.speakers[label] == nil {
            draft.speakers[label] = label
        }
        self.draft = draft

        let attendees = inputs.calendar?.event?.attendees ?? []
        let configuredSelfName = configuredSelfWikilink
            .flatMap { try? SelfWikilink.normalized($0) }
            .map(SpeakerNaming.bareName)
            .flatMap(Self.nonEmpty)
        selfName = configuredSelfName ?? attendees.first { $0.isSelf }?.displayName.flatMap(Self.nonEmpty)
        knownNames = Self.orderedUnique(attendees.compactMap { $0.displayName.flatMap(Self.nonEmpty) } + glossary.people + previous.previousNames())
        suggestedSelfSpeaker = Self.longestSpeaker(in: inputs.diarization)
        recurringPrefill = Self.prefill(
            labels: labels,
            seriesTitle: inputs.calendar?.event?.title,
            previous: previous,
            glossary: glossary,
        )
    }

    // MARK: - Reading

    /// `knownNames` that start with `prefix`, case-insensitively, in the same
    /// order. An empty prefix offers all of them.
    public func autocomplete(prefix: String) -> [String] {
        let folded = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !folded.isEmpty else { return knownNames }
        return knownNames.filter { $0.lowercased().hasPrefix(folded) }
    }

    /// The bare name currently given to `label`, `nil` while it is a
    /// placeholder.
    public func name(forSpeaker label: String) -> String? {
        guard let value = draft.speakers[label] else { return nil }
        let bare = SpeakerNaming.bareName(value)
        return bare.isEmpty || SpeakerNaming.isPlaceholder(bare) ? nil : bare
    }

    /// True while any speaker still carries its placeholder.
    public var hasUnattributedSpeakers: Bool {
        diarization.speakerLabels.contains { name(forSpeaker: $0) == nil }
    }

    // MARK: - Mutations

    /// Names `label`. A name matching a vault person uses the vault's
    /// spelling; any other becomes `[[Name]]` text with no vault file. An
    /// empty name restores the placeholder.
    public func setName(_ name: String, forSpeaker label: String) {
        guard diarization.speakerLabels.contains(label) else { return }
        draft.speakers[label] = SpeakerNaming.value(forName: name, label: label, glossary: glossary)
        markDirty()
    }

    /// Gives `suggestedSelfSpeaker` the calendar's own attendee name. Does
    /// nothing when either is unknown.
    public func markThisIsMe() {
        guard let suggestedSelfSpeaker, let selfName else { return }
        setName(selfName, forSpeaker: suggestedSelfSpeaker)
    }

    /// Fills every still-unnamed speaker that has a proposal.
    public func applyRecurringPrefill() {
        for (label, name) in recurringPrefill.sorted(by: { $0.key < $1.key }) where self.name(forSpeaker: label) == nil {
            setName(name, forSpeaker: label)
        }
    }

    /// Reassigns one paragraph. A later call for the same segment replaces the
    /// earlier one.
    public func setOverride(segmentID: String, name: String) {
        guard diarization.segments.contains(where: { $0.id == segmentID }) else { return }
        let value = SpeakerNaming.value(forName: name, label: segmentLabel(segmentID), glossary: glossary)
        draft.segmentOverrides.removeAll { $0.segmentId == segmentID }
        draft.segmentOverrides.append(SegmentOverride(segmentId: segmentID, speaker: value))
        markDirty()
    }

    public func clearOverride(segmentID: String) {
        let before = draft.segmentOverrides.count
        draft.segmentOverrides.removeAll { $0.segmentId == segmentID }
        if draft.segmentOverrides.count != before {
            markDirty()
        }
    }

    /// Replaces any earlier split of the same segment. A split needs two or
    /// more parts and a segment that `diarization.json` has.
    public func setSplit(_ split: SegmentSplit) {
        guard split.splits.count >= 2, diarization.segments.contains(where: { $0.id == split.originalSegmentId }) else { return }
        draft.segmentSplits.removeAll { $0.originalSegmentId == split.originalSegmentId }
        draft.segmentSplits.append(split)
        markDirty()
    }

    public func removeSplit(originalSegmentID: String) {
        let before = draft.segmentSplits.count
        draft.segmentSplits.removeAll { $0.originalSegmentId == originalSegmentID }
        if draft.segmentSplits.count != before {
            markDirty()
        }
    }

    // MARK: - Writing

    /// Cancels the pending debounced write, waits for any write in flight, and
    /// writes the latest draft now if it is not already on disk. When it
    /// returns without `lastWriteError`, the file equals `draft`.
    public func flush() async {
        let pending = pendingWrite
        pendingWrite = nil
        pending?.cancel()
        await pending?.value
        if hasUnsavedChanges {
            writeDraft()
        }
    }

    private func markDirty() {
        hasUnsavedChanges = true
        pendingWrite?.cancel()
        let sleep = sleep
        pendingWrite = Task { @MainActor [weak self] in
            do {
                try await sleep(Self.debounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            pendingWrite = nil
            writeDraft()
        }
    }

    /// Runs on the main actor start to finish, so a cancel arriving from
    /// `flush` or a newer edit either lands before the write begins or after it
    /// ends, never inside it.
    private func writeDraft() {
        let snapshot = draft
        do {
            try writer(snapshot)
            lastWriteError = nil
            if draft == snapshot {
                hasUnsavedChanges = false
            }
        } catch {
            let errorType = String(reflecting: type(of: error))
            lastWriteError = errorType
            log.warn("attribution write failed", ["error": .publicSafe(errorType)])
        }
    }

    // MARK: - Derivations

    private func segmentLabel(_ segmentID: String) -> String {
        diarization.segments.first { $0.id == segmentID }?.speakerLabel ?? segmentID
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func orderedUnique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap(nonEmpty).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Ties go to the speaker who appears first.
    private static func longestSpeaker(in diarization: DiarizationArtifact) -> String? {
        var totals: [String: Double] = [:]
        for segment in diarization.segments {
            totals[segment.speakerLabel, default: 0] += max(0, segment.endSeconds - segment.startSeconds)
        }
        return diarization.speakerLabels.reduce(nil as String?) { best, label in
            guard let best else { return label }
            return totals[label, default: 0] > totals[best, default: 0] ? label : best
        }
    }

    /// `Speaker_N` is numbered by first appearance, not identity, so a name is
    /// proposed only when the same label carried it in several earlier meetings.
    private static func prefill(labels: [String], seriesTitle: String?, previous: any PreviousLabelings, glossary: Glossary) -> [String: String] {
        guard let seriesTitle, !labels.isEmpty else { return [:] }
        var counts: [String: [String: (name: String, count: Int)]] = [:]
        for map in previous.speakerMaps(inSeries: seriesTitle) {
            for label in labels {
                let name = SpeakerNaming.bareName(map[label] ?? "")
                guard !name.isEmpty, !SpeakerNaming.isPlaceholder(name) else { continue }
                let key = name.lowercased()
                let held = counts[label]?[key]
                counts[label, default: [:]][key] = (name: held?.name ?? name, count: (held?.count ?? 0) + 1)
            }
        }
        var proposals: [String: String] = [:]
        for label in labels {
            let qualifying = (counts[label] ?? [:]).values.filter { $0.count >= prefillThreshold }
            if let best = qualifying.max(by: { ($0.count, $1.name) < ($1.count, $0.name) }) {
                proposals[label] = SpeakerNaming.canonicalName(best.name, glossary: glossary)
            }
        }
        return proposals
    }
}
