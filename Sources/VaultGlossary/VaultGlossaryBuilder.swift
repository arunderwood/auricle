import Core
import Foundation

public enum VaultGlossaryError: Error, Equatable, Sendable {
    /// The vault path does not name a directory.
    case vaultPathMissing
    /// The vault directory exists but its entries cannot be listed.
    case vaultUnreadable
}

/// Builds the glossary of terms an Obsidian vault already uses (FR55): the
/// name of every markdown page, plus every `[[wikilink]]` target found in a
/// page's text. The links matter as much as the pages, because notes are
/// linked long before they are written; a ghost link is a term the maintainer
/// has already decided is worth naming.
///
/// The scan is cached under the app's cache root and reused until the vault
/// changes, so a run that finds the vault unchanged reads one small file
/// instead of every note.
public struct VaultGlossaryBuilder: Sendable {
    public struct Outcome: Sendable, Equatable {
        public let glossary: Glossary
        /// `false` when the cached glossary was still current and no note was read.
        public let rebuilt: Bool

        public init(glossary: Glossary, rebuilt: Bool) {
            self.glossary = glossary
            self.rebuilt = rebuilt
        }
    }

    public static let defaultMeetingsSubdir = "Meetings"

    private let vaultPath: URL
    private let meetingsSubdirComponents: [String]
    private let cacheRoot: URL?

    /// - Parameters:
    ///   - meetingsSubdir: Skipped, with everything under it, so the notes
    ///     auricle itself writes never feed back into the vocabulary it is
    ///     corrected against.
    ///   - cacheRoot: Where `glossary-cache.json` lives. `nil` is the app's
    ///     cache root; if that cannot be resolved the build simply runs
    ///     uncached.
    public init(vaultPath: URL, meetingsSubdir: String = defaultMeetingsSubdir, cacheRoot: URL? = nil) {
        self.vaultPath = vaultPath
        meetingsSubdirComponents = meetingsSubdir
            .split(separator: "/")
            .map { $0.lowercased() }
        self.cacheRoot = cacheRoot ?? (try? CacheArtifactWriter.cacheRoot())
    }

    public func build() throws(VaultGlossaryError) -> Outcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vaultPath.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .vaultPathMissing
        }

        let entries = try walk()
        let fingerprint = fingerprint(of: entries)
        let normalizedPath = vaultPath.standardizedFileURL.path

        if let cacheRoot, let cache = GlossaryCache.fresh(in: cacheRoot, vaultPath: normalizedPath, fingerprint: fingerprint) {
            return Outcome(glossary: cache.glossary, rebuilt: false)
        }

        let glossary = Self.scan(entries)
        if let cacheRoot {
            GlossaryCache(vaultPath: normalizedPath, fingerprint: fingerprint, glossary: glossary).store(in: cacheRoot)
        }
        return Outcome(glossary: glossary, rebuilt: true)
    }

    /// A missing or unreadable vault is not a reason to withhold a note, so
    /// this never throws. `report` is told why the glossary is empty.
    public func buildOrEmpty(reportingTo report: (VaultGlossaryError) -> Void = { _ in }) -> Glossary {
        do {
            return try build().glossary
        } catch {
            report(error)
            return Glossary()
        }
    }

    // MARK: - Walking

    private struct Entry {
        let url: URL
        /// Path components below the vault root, ending with this entry's own name.
        let components: [String]
        let isDirectory: Bool
        let modified: Date?
    }

    private static let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]

    /// Every file and directory the scan does not skip, in a fixed order.
    /// Symlinked directories are neither followed nor counted: a link back up
    /// the tree would never end, and one out of the vault would pull in notes
    /// that are not the vault's.
    private func walk() throws(VaultGlossaryError) -> [Entry] {
        var entries: [Entry] = []
        let rootEntry = Entry(url: vaultPath, components: [], isDirectory: true, modified: modificationDate(of: vaultPath))
        entries.append(rootEntry)
        try visit(directory: vaultPath, components: [], into: &entries)
        return entries
    }

    private func visit(directory: URL, components: [String], into entries: inout [Entry]) throws(VaultGlossaryError) {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Self.resourceKeys,
                options: [.skipsHiddenFiles],
            )
        } catch {
            if components.isEmpty {
                throw .vaultUnreadable
            }
            return
        }

        for child in children.sorted(by: Self.byName) {
            let name = child.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let values = try? child.resourceValues(forKeys: Set(Self.resourceKeys))
            var isDirectory = values?.isDirectory ?? false
            if values?.isSymbolicLink == true {
                var targetIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &targetIsDirectory), !targetIsDirectory.boolValue else {
                    continue
                }
                isDirectory = false
            }

            let childComponents = components + [name]
            if isDirectory {
                if !meetingsSubdirComponents.isEmpty, childComponents.map({ $0.lowercased() }) == meetingsSubdirComponents {
                    continue
                }
                entries.append(Entry(url: child, components: childComponents, isDirectory: true, modified: values?.contentModificationDate))
                try visit(directory: child, components: childComponents, into: &entries)
            } else {
                if Self.isMarkdown(name), WikilinkScanner.isDateNamed(name) {
                    continue
                }
                entries.append(Entry(url: child, components: childComponents, isDirectory: false, modified: values?.contentModificationDate))
            }
        }
    }

    private static func byName(_ first: URL, _ second: URL) -> Bool {
        let (firstName, secondName) = (first.lastPathComponent, second.lastPathComponent)
        return (firstName.lowercased(), firstName) < (secondName.lowercased(), secondName)
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func fingerprint(of entries: [Entry]) -> VaultFingerprint {
        let newest = entries.compactMap(\.modified).max()
        // The vault root is an entry only so its own date counts.
        return VaultFingerprint(newestModification: newest?.timeIntervalSince1970, entryCount: entries.count - 1)
    }

    // MARK: - Scanning

    private static func isMarkdown(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".md")
    }

    private enum Category {
        case people
        case projects
        case concepts

        init?(folder: String) {
            switch folder.lowercased() {
            case "people": self = .people
            case "projects": self = .projects
            case "concepts": self = .concepts
            default: return nil
            }
        }
    }

    private struct Page {
        let name: String
        let category: Category?
    }

    /// Reads every markdown page. A page name wins over a link to the same
    /// term, because the page says which category the term belongs to; two
    /// spellings of one term keep whichever the fixed walk order meets first.
    private static func scan(_ entries: [Entry]) -> Glossary {
        var pages: [String: Page] = [:]
        var linkedTerms: [String: String] = [:]

        for entry in entries where !entry.isDirectory && isMarkdown(entry.components.last ?? "") {
            if let page = page(for: entry), pages[page.name.lowercased()] == nil {
                pages[page.name.lowercased()] = page
            }
            guard let data = try? Data(contentsOf: entry.url) else { continue }
            for target in WikilinkScanner.targets(in: data) where linkedTerms[target.lowercased()] == nil {
                linkedTerms[target.lowercased()] = target
            }
        }

        var people: [String] = []
        var projects: [String] = []
        var concepts: [String] = []
        var uncategorized: [String] = []
        for page in pages.values {
            switch page.category {
            case .people: people.append(page.name)
            case .projects: projects.append(page.name)
            case .concepts: concepts.append(page.name)
            case nil: uncategorized.append(page.name)
            }
        }
        for (key, term) in linkedTerms where pages[key] == nil {
            uncategorized.append(term)
        }

        return Glossary(
            people: sorted(people),
            projects: sorted(projects),
            concepts: sorted(concepts),
            uncategorized: sorted(uncategorized),
        )
    }

    /// The nearest ancestor folder named for a category decides it, so a
    /// `People` folder inside a `Projects` folder still holds people.
    private static func page(for entry: Entry) -> Page? {
        guard let fileName = entry.components.last else { return nil }
        let name = String(fileName.dropLast(".md".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let category = entry.components.dropLast().reversed().lazy.compactMap { Category(folder: $0) }.first
        return Page(name: name, category: category)
    }

    private static func sorted(_ terms: [String]) -> [String] {
        terms.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
    }
}
