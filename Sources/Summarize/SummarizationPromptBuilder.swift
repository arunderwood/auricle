import Core
import CryptoKit
import Foundation

/// Selects which mode-specific addendum file (`citations.md`/`substring.md`)
/// `SummarizationPromptBuilder` appends to the shared `system.md`. Spelled
/// identically to `GroundingMethod` but declared separately: `GroundingMethod`
/// (`SummarizerInterface`) is fixed as "telemetry-only, never a downstream
/// control flag" (Story 3.1), and selecting a prompt file is exactly a
/// control flag.
public enum SummarizationMode: String, Sendable, CaseIterable {
    case citations
    case substring

    var fileName: String {
        "\(rawValue).md"
    }
}

/// One piece of the composed prompt, tagged with whether the caller should
/// mark it for Anthropic prompt caching (`cache_control`). The transcript is
/// unique per meeting so it is never cacheable; the other three blocks are
/// stable across consecutive calls in a session.
public struct PromptBlock: Sendable, Equatable {
    public let text: String
    public let cacheable: Bool

    public init(text: String, cacheable: Bool) {
        self.text = text
        self.cacheable = cacheable
    }
}

/// The fully composed prompt for one `summarize()` call, plus the hash of
/// the prompt-file bytes that produced it.
public struct SummarizationPrompt: Sendable, Equatable {
    public let system: PromptBlock
    public let glossary: PromptBlock
    public let attendeeContext: PromptBlock
    public let transcript: PromptBlock
    /// Lowercase-hex SHA-256 over the resolved `system.md` and mode-file
    /// bytes actually used for this call — telemetry's answer to "why did
    /// this note come out worse," since the prompt set is now an editable
    /// file a user can silently change.
    public let promptSetHash: String

    public init(
        system: PromptBlock,
        glossary: PromptBlock,
        attendeeContext: PromptBlock,
        transcript: PromptBlock,
        promptSetHash: String,
    ) {
        self.system = system
        self.glossary = glossary
        self.attendeeContext = attendeeContext
        self.transcript = transcript
        self.promptSetHash = promptSetHash
    }
}

/// File-resolution failures only: `SummarizerError` (`SummarizerInterface`)
/// describes API-call failures, and none of its cases fit a prompt-file I/O
/// problem, which happens before any network call is made.
public enum SummarizationPromptBuilderError: Error, Sendable, Equatable {
    /// A file the shipped default set is supposed to carry
    /// (`Prompts/summarize/<file>`) isn't in the built resource bundle, or is
    /// present but its bytes aren't valid UTF-8 — either way a packaging
    /// defect, not a condition a correctly built app can hit.
    case bundledPromptResourceMissing(file: String)
    /// `promptDir/<file>` exists but couldn't be read, or its bytes aren't
    /// valid UTF-8.
    case overridePromptFileUnreadable(file: String)
}

/// Composes the Claude summarization prompt from markdown files on disk
/// instead of Swift string literals, so editing how notes are summarized
/// means editing a file, never a rebuild (FR58/FR59). `system.md` is shared
/// by both grounding modes verbatim — the equivalence the two strategies
/// must preserve is structural (one file, read twice), not a property a
/// test has to separately verify.
public enum SummarizationPromptBuilder {
    private static let systemFileName = "system.md"
    private static let bundledResourceSubdirectory = "Prompts/summarize"

    /// - Parameter promptDir: When non-nil, each needed file is read from
    ///   here first; a file absent from `promptDir` falls back to the
    ///   bundled default. `promptDir` is caller-supplied — resolving it from
    ///   config or a CLI flag is the summarize stage's job (Story 3.7), not
    ///   this builder's.
    public static func build(
        transcript: CanonicalTranscript,
        glossary: Glossary,
        attendees: [String],
        mode: SummarizationMode,
        promptDir: URL? = nil,
    ) throws -> SummarizationPrompt {
        try build(
            transcript: transcript,
            glossary: glossary,
            attendees: attendees,
            mode: mode,
            promptDir: promptDir,
            bundle: .module,
        )
    }

    /// The hash `build(...)` would return for `mode` and `promptDir`, without
    /// composing a prompt. It is a pure function of the two resolved files, so
    /// a caller that needs the hash but not the prompt (the summarize stage,
    /// which records it in telemetry while the strategies build the prompts)
    /// gets exactly the value the strategy's own `build` call produces —
    /// provided it passes the same `promptDir` the strategy does. Throws the
    /// same `SummarizationPromptBuilderError` `build` would.
    public static func promptSetHash(mode: SummarizationMode, promptDir: URL? = nil) throws -> String {
        let files = try resolvePromptFiles(mode: mode, promptDir: promptDir, bundle: .module)
        return promptSetHash(of: files)
    }

    /// Bundle-injecting overload, `internal` so only `@testable import`
    /// callers can reach it — exercises the "bundled resource missing"
    /// packaging-defect path through the real `build()` logic, against a
    /// bundle that deliberately doesn't carry `Prompts/summarize/`, rather
    /// than deleting a file from the shipped bundle at test time.
    static func build(
        transcript: CanonicalTranscript,
        glossary: Glossary,
        attendees: [String],
        mode: SummarizationMode,
        promptDir: URL?,
        bundle: Bundle,
    ) throws -> SummarizationPrompt {
        let files = try resolvePromptFiles(mode: mode, promptDir: promptDir, bundle: bundle)
        let composedSystemText = resolvedText(from: files.system) + "\n\n" + resolvedText(from: files.mode)

        return SummarizationPrompt(
            system: PromptBlock(text: composedSystemText, cacheable: true),
            glossary: PromptBlock(text: renderGlossary(glossary), cacheable: true),
            attendeeContext: PromptBlock(text: renderAttendees(attendees), cacheable: true),
            transcript: PromptBlock(text: transcript.text, cacheable: false),
            promptSetHash: promptSetHash(of: files),
        )
    }

    // MARK: - File resolution

    /// The raw bytes of the two files one mode's prompt is built from.
    private struct PromptFiles {
        let system: Data
        let mode: Data
    }

    private static func resolvePromptFiles(mode: SummarizationMode, promptDir: URL?, bundle: Bundle) throws -> PromptFiles {
        try PromptFiles(
            system: resolveFile(named: systemFileName, promptDir: promptDir, bundle: bundle),
            mode: resolveFile(named: mode.fileName, promptDir: promptDir, bundle: bundle),
        )
    }

    /// Hashes the untrimmed raw bytes, `system.md` then a newline separator
    /// then the mode file, so the hash reflects exactly what was read.
    private static func promptSetHash(of files: PromptFiles) -> String {
        var hasher = SHA256()
        hasher.update(data: files.system)
        hasher.update(data: Data([0x0A]))
        hasher.update(data: files.mode)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `promptDir` is never assumed to hold every file: each of the (at
    /// most two) files this call needs is resolved independently, so a
    /// `promptDir` overriding only `system.md` still gets the bundled
    /// mode file rather than failing outright.
    private static func resolveFile(named fileName: String, promptDir: URL?, bundle: Bundle) throws -> Data {
        if let promptDir {
            let overrideURL = promptDir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: overrideURL.path) {
                guard let data = try? Data(contentsOf: overrideURL),
                      let text = String(bytes: data, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw SummarizationPromptBuilderError.overridePromptFileUnreadable(file: fileName)
                }
                return data
            }
        }

        let baseName = (fileName as NSString).deletingPathExtension
        let extensionName = (fileName as NSString).pathExtension
        guard let url = bundle.url(forResource: baseName, withExtension: extensionName, subdirectory: bundledResourceSubdirectory),
              let data = try? Data(contentsOf: url),
              String(bytes: data, encoding: .utf8) != nil
        else {
            throw SummarizationPromptBuilderError.bundledPromptResourceMissing(file: fileName)
        }
        return data
    }

    /// Trims surrounding whitespace/newlines so a shipped file's trailing
    /// newline (the normal shape of a checked-in text file) doesn't turn
    /// the caller-visible "blank line" between `system.md` and the mode
    /// file into two blank lines. `promptSetHash` hashes the untrimmed raw
    /// bytes instead, since it must reflect exactly what was read. The `??
    /// ""` never actually fires: `resolveFile` already rejects an override
    /// file that isn't valid UTF-8, and a bundled file is our own shipped
    /// content.
    private static func resolvedText(from data: Data) -> String {
        (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Glossary / attendee rendering

    /// Only glossary terms get wrapped in `[[wikilink]]` form (matches vault
    /// rendering); attendee names are plain per the AC. `uncategorized`
    /// renders as a fourth, only-when-non-empty line so Story 3.12's
    /// non-standard-vault fallback still reaches the model it exists to
    /// help, without changing the standard-vault (empty `uncategorized`)
    /// snapshot.
    private static func renderGlossary(_ glossary: Glossary) -> String {
        let categories: [(label: String, terms: [String])] = [
            ("People", glossary.people),
            ("Projects", glossary.projects),
            ("Concepts", glossary.concepts),
            ("Uncategorized", glossary.uncategorized),
        ]
        let lines = categories.compactMap { category -> String? in
            guard !category.terms.isEmpty else { return nil }
            let wikilinked = category.terms.map { "[[\($0)]]" }.joined(separator: ", ")
            return "- \(category.label): \(wikilinked)"
        }
        guard !lines.isEmpty else { return "" }
        return (["Glossary (terms from your vault, prefer these spellings):"] + lines).joined(separator: "\n")
    }

    private static func renderAttendees(_ attendees: [String]) -> String {
        guard !attendees.isEmpty else { return "" }
        return "Attendees: \(attendees.joined(separator: ", "))"
    }
}
