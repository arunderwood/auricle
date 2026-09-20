import Core
import Foundation

/// Finds the note already published for a meeting by what the note says, not
/// where it sits: a user who renames a note or moves it into a subfolder in
/// Obsidian leaves `meetings.vault_note_path` pointing at nothing, but the
/// note's `auricle.meeting_id` still names the meeting.
enum PredecessorNoteFinder {
    /// Files examined before the scan gives up. A meetings folder this large
    /// is not a realistic vault layout, and every file costs a read.
    static let maxScannedFiles = 5000

    /// Only the frontmatter is read from each file, never the body, so a note
    /// with a long transcript costs no more than a short one. Frontmatter is
    /// a short metadata block; a closing fence still missing after this many
    /// bytes is not one `FrontmatterRenderer` wrote.
    static let maxFrontmatterBytes = 8 * 1024

    static let log = Log(category: "persist-stage")

    private static let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]

    struct Candidate: Equatable {
        let url: URL
        let supersedes: String?
        let modified: Date
    }

    /// Recursively scans `directory` for an `.md` file whose `auricle.meeting_id`
    /// is `meetingID`, and returns the one that is the meeting's current note,
    /// or `nil` when no file names the meeting. Hidden files and folders are
    /// not searched, and symlinks are not followed. A file that is unreadable,
    /// not UTF-8, not an auricle note, or whose frontmatter does not parse
    /// never matches.
    static func find(
        meetingID: MeetingID,
        in directory: URL,
        maxFiles: Int = maxScannedFiles,
        log: Log = log,
    ) -> URL? {
        var candidates: [Candidate] = []
        var scanned = 0
        var pending = [directory]
        while let current = pending.popLast() {
            for child in children(of: current) {
                guard let values = try? child.resourceValues(forKeys: Set(resourceKeys)) else {
                    continue
                }
                if values.isDirectory == true {
                    pending.append(child)
                    continue
                }
                guard values.isRegularFile == true else {
                    continue
                }
                guard scanned < maxFiles else {
                    log.warn("predecessor note scan stopped at its file limit", ["limit": .publicSafe(maxFiles)])
                    return predecessor(among: candidates)
                }
                scanned += 1

                guard
                    child.pathExtension.lowercased() == "md",
                    let frontmatter = readFrontmatter(at: child),
                    frontmatter.meetingID == meetingID
                else {
                    continue
                }
                candidates.append(Candidate(
                    url: child,
                    supersedes: frontmatter.supersedes,
                    modified: values.contentModificationDate ?? .distantPast,
                ))
            }
        }
        return predecessor(among: candidates)
    }

    /// An original and its re-runs all carry the meeting's id, and each
    /// re-run's `supersedes` names the note it replaced. The current note is
    /// the one no other candidate supersedes. When that still leaves several
    /// (a note renamed after its re-run was written no longer matches the
    /// re-run's `supersedes`), or none (a lineage that loops back on itself),
    /// the most recently modified of the remaining candidates is the note the
    /// user last touched; the path breaks a tie so the pick never depends on
    /// enumeration order.
    static func predecessor(among candidates: [Candidate]) -> URL? {
        let unsuperseded = candidates.filter { candidate in
            !candidates.contains { other in
                other.url != candidate.url && other.supersedes == candidate.url.lastPathComponent
            }
        }
        let pool = unsuperseded.isEmpty ? candidates : unsuperseded
        return pool.min { first, second in
            if first.modified != second.modified {
                return first.modified > second.modified
            }
            return first.url.path < second.url.path
        }?.url
    }

    /// The visible entries of `directory` in name order, so a scan that hits
    /// its file limit covers the same files on every run. Each URL is built
    /// from `directory` as given: `FileManager`'s URL-returning listings
    /// resolve symlinks in the root (`/var` becomes `/private/var`), and a
    /// path recorded from a match must be spelled the way the configured vault
    /// path is. An unreadable directory has no entries.
    private static func children(of directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// `nil` for a file that cannot be read, is not UTF-8, or has no auricle
    /// frontmatter this reader accepts.
    private static func readFrontmatter(at url: URL) -> FrontmatterReader.FrontmatterV1? {
        guard let head = frontmatterText(of: url) else {
            return nil
        }
        return try? FrontmatterReader.read(noteContents: head)
    }

    /// The first `maxFrontmatterBytes` of the file, cut back to the last full
    /// line when the read filled the buffer: a byte limit can split a
    /// multi-byte character, and a line break never falls inside one.
    private static func frontmatterText(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard var head = try? handle.read(upToCount: maxFrontmatterBytes) else {
            return nil
        }
        if head.count == maxFrontmatterBytes, let lastLineBreak = head.lastIndex(of: UInt8(ascii: "\n")) {
            head = head[..<lastLineBreak]
        }
        return String(data: head, encoding: .utf8)
    }
}
