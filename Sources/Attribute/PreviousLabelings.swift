import Core
import Foundation

/// The names attribution has given speakers before, for autocomplete and for
/// recurring-meeting prefill.
public protocol PreviousLabelings: Sendable {
    /// Bare names (no brackets), most recently used first, each once.
    func previousNames() -> [String]

    /// The `speakers` map of each earlier meeting whose calendar event title
    /// matches `seriesTitle` (trimmed, case-folded), placeholders included.
    func speakerMaps(inSeries seriesTitle: String) -> [[String: String]]
}

/// No history: what a first run, a test, or a caller that has none passes.
public struct NoPreviousLabelings: PreviousLabelings {
    public init() {}

    public func previousNames() -> [String] {
        []
    }

    public func speakerMaps(inSeries _: String) -> [[String: String]] {
        []
    }
}

/// History read from the per-meeting cache: each meeting's `attribution.json`
/// and `calendar.json` under the cache root. Retention purges those caches, so
/// what it knows is bounded by the retention window.
public struct CachedAttributionLabelings: PreviousLabelings {
    private let cacheRoot: URL
    private let excluding: String?

    /// - Parameter excluding: The meeting being attributed, whose own file is
    ///   not history.
    public init(cacheRoot: URL, excluding: MeetingID? = nil) {
        self.cacheRoot = cacheRoot
        self.excluding = excluding?.rawValue
    }

    /// The series key for a calendar event title.
    static func seriesKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct Entry {
        let modified: Date
        let speakers: [String: String]
        let seriesKey: String?
    }

    /// Newest first. An unreadable or undecodable meeting is skipped: history
    /// is an aid, and one damaged file must not hide the rest.
    private func entries() -> [Entry] {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else { return [] }
        var entries: [Entry] = []
        for directory in directories where directory.lastPathComponent != excluding {
            let attributionURL = directory.appendingPathComponent(AttributionArtifact.fileName)
            guard let file = try? AttributionFile.read(in: directory),
                  let modified = (try? fileManager.attributesOfItem(atPath: attributionURL.path))?[.modificationDate] as? Date
            else { continue }
            let title = (try? JSONDecoder().decode(CalendarArtifact.self, from: Data(contentsOf: directory.appendingPathComponent("calendar.json"))))?.event?.title
            entries.append(Entry(modified: modified, speakers: file.speakers, seriesKey: title.map(Self.seriesKey)))
        }
        return entries.sorted { $0.modified > $1.modified }
    }

    public func previousNames() -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for entry in entries() {
            for label in entry.speakers.keys.sorted() {
                let name = SpeakerNaming.bareName(entry.speakers[label] ?? "")
                if !name.isEmpty, !SpeakerNaming.isPlaceholder(name), seen.insert(name.lowercased()).inserted {
                    names.append(name)
                }
            }
        }
        return names
    }

    public func speakerMaps(inSeries seriesTitle: String) -> [[String: String]] {
        let key = Self.seriesKey(seriesTitle)
        guard !key.isEmpty else { return [] }
        return entries().filter { $0.seriesKey == key }.map(\.speakers)
    }
}
