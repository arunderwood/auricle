import Foundation
import TOMLKit

/// Edits a single key in the config file (FR59), `Config.defaultFileURL()`:
/// `~/.auricle/config.toml` unless `AURICLE_CONFIG` names another. It edits
/// by rewriting the raw file text, not by parsing the document into a
/// `TOMLTable` and reserializing it. `TOMLKit`'s backend discards comment tokens while
/// parsing (`consume_comment()` in its vendored `toml.hpp`) and nothing in
/// its node model stores them, so a parse/mutate/reserialize round trip would
/// silently delete every comment in a file this app promises is safe to
/// hand-edit. `TOMLKit` is still used, but only to render the one new value
/// as a correctly escaped TOML literal.
///
/// Only two existing representations of a nested key are recognized: a
/// fully-dotted line (`table.leaf = ...`) at the root, or a `[table]`
/// section. A file using some other valid-but-unrecognized TOML shape for
/// the same name (an inline table, a quoted key or header, a dotted key
/// with embedded spaces, ...) isn't edited in place; `set` re-parses the
/// result with `Config.parse` before writing and throws
/// `WriterError.wouldProduceInvalidConfig` rather than silently writing an
/// unreadable file, so the worst case is a safe rejection, never corruption.
public enum ConfigWriter {
    public enum WriterError: Error, Sendable, Equatable {
        /// `key` is empty, exactly `"."`, starts or ends with `.`, or has a
        /// dot-component containing a character illegal in a bare TOML key.
        case invalidKey(key: String)
        /// `key` looks credential-shaped (matches NFR-S1's secret patterns)
        /// and isn't the one documented exception, `google_calendar.client_secret`.
        case secretRejected(key: String)
        /// `key` is well formed but is not one `Config` reads
        /// (`Config.settableKeys`).
        case unknownKey(key: String)
        /// The existing file's contents are not valid UTF-8.
        case malformed
        /// The file was already unreadable before this edit. Reported apart
        /// from `wouldProduceInvalidConfig` so the message sends the user to
        /// the file, not to the value they tried to set.
        case existingConfigInvalid(ConfigError)
        /// Applying the edit would leave `Config.parse` unable to read the
        /// file — the file is left untouched when this is thrown.
        case wouldProduceInvalidConfig(ConfigError)

        public var message: String {
            switch self {
            case let .invalidKey(key):
                "\"\(key)\" is not a valid config key."
            case let .secretRejected(key):
                "\"\(key)\" looks like a credential; store it in Keychain, not config.toml."
            case let .unknownKey(key):
                "\"\(key)\" is not a setting auricle reads. Settable keys: \(Config.settableKeys.joined(separator: ", "))."
            case .malformed:
                "the existing config file is not valid UTF-8."
            case let .existingConfigInvalid(underlying):
                "the existing config file is already unreadable (\(underlying)); fix or remove it, then try again. It was left untouched."
            case let .wouldProduceInvalidConfig(underlying):
                "this edit would make the config unreadable (\(underlying)) — the file was left untouched."
            }
        }
    }

    /// Case-insensitive substrings of a credential-shaped key (NFR-S1).
    /// `google_calendar.client_secret` is the one documented exception
    /// (`Config`'s own doc comment): Google issues Desktop-type clients a
    /// secret it documents as non-confidential.
    private static let secretKeyPatterns = ["api_key", "token", "secret", "password"]
    private static let secretKeyExceptions: Set<String> = ["google_calendar.client_secret"]

    /// `fileURL`, `homeDirectory` and `environment` mirror `Config.load`'s
    /// own test-seam parameters, so a caller passing none of them writes
    /// exactly where `Config.load` reads, and a test never touches the real
    /// `~/.auricle`.
    ///
    /// The credential check runs before the settable-key check, so a
    /// credential-shaped key is always refused as a credential.
    public static func set(
        _ key: String,
        to value: String,
        fileURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) throws {
        guard !key.isEmpty, !key.hasPrefix("."), !key.hasSuffix(".") else {
            throw WriterError.invalidKey(key: key)
        }
        guard key.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isValidBareKeyComponent) else {
            throw WriterError.invalidKey(key: key)
        }
        guard !isSecretShaped(key) else {
            throw WriterError.secretRejected(key: key)
        }
        guard Config.settableKeys.contains(key) else {
            throw WriterError.unknownKey(key: key)
        }

        let url = fileURL ?? Config.defaultFileURL(homeDirectory: homeDirectory, environment: environment)
        let existingText = try readExistingText(at: url)
        do {
            _ = try Config.parse(existingText, homeDirectory: homeDirectory)
        } catch let error as ConfigError {
            throw WriterError.existingConfigInvalid(error)
        }
        let literal = try formattedLiteral(for: normalizedValue(value, key: key), key: key)
        let updatedText = apply(key: key, literal: literal, to: existingText)

        do {
            _ = try Config.parse(updatedText, homeDirectory: homeDirectory)
        } catch let error as ConfigError {
            throw WriterError.wouldProduceInvalidConfig(error)
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWriter.write(Data(updatedText.utf8), to: url)
    }

    /// `self.wikilink` is stored in `SelfWikilink.normalized` form, so
    /// `set("self.wikilink", to: "Jordan")` writes `"[[Jordan]]"`. An empty
    /// value passes through unchanged: it is how a user unsets the key.
    private static func normalizedValue(_ value: String, key: String) throws -> String {
        guard key == "self.wikilink", !value.isEmpty else { return value }
        do {
            return try SelfWikilink.normalized(value)
        } catch {
            throw WriterError.wouldProduceInvalidConfig(.invalidValue(key: key, reason: error.reason))
        }
    }

    private static func isSecretShaped(_ key: String) -> Bool {
        guard !secretKeyExceptions.contains(key) else { return false }
        let lowered = key.lowercased()
        return secretKeyPatterns.contains { lowered.contains($0) }
    }

    /// A missing file reads as empty text — `set` then writes a file
    /// containing only the new key, creating both the file and its parent
    /// directory.
    private static func readExistingText(at url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return ""
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WriterError.malformed
        }
        return text
    }

    /// The non-`String` fields `Config`'s schema declares today. Every other
    /// settable key is written as a string; the `wouldProduceInvalidConfig`
    /// guard in `set` catches a value that doesn't actually parse as its
    /// schema type.
    private enum LiteralKind {
        case bool, int, string
    }

    private static func literalKind(for key: String) -> LiteralKind {
        switch key {
        case "diarization_review.enabled": .bool
        case "attribution.snippet_duration_seconds": .int
        default: .string
        }
    }

    /// `options: []` disables `.allowLiteralStrings`, so a string value that
    /// would otherwise render as a single-quoted TOML literal always renders
    /// as a double-quoted basic string, matching what `replacingValue`
    /// expects to find on a later edit.
    private static func formattedLiteral(for value: String, key: String) -> String {
        switch literalKind(for: key) {
        case .bool:
            if let boolValue = Bool(value) {
                return boolValue ? "true" : "false"
            }
        case .int:
            if let intValue = Int(value) {
                return String(intValue)
            }
        case .string:
            break
        }
        let rendered = TOMLTable(["v": value]).convert(to: .toml, options: [])
        let prefix = "v = "
        var literal = rendered.hasPrefix(prefix) ? String(rendered.dropFirst(prefix.count)) : rendered
        while literal.hasSuffix("\n") {
            literal.removeLast()
        }
        return literal
    }
}

/// The raw-text line search/replace engine `set` above drives. Split into its
/// own extension so `ConfigWriter`'s two type bodies each stay under
/// swiftlint's `type_body_length`.
private extension ConfigWriter {
    /// Normalizes CRLF to LF before the line-based logic below (which knows
    /// only `\n`), then restores CRLF on the way out if that's what the
    /// original file used -- so a Windows-authored or `core.autocrlf`-mangled
    /// config round-trips with its own line ending, rather than silently
    /// gaining a mismatched `\n` section that later fails to parse.
    static func apply(key: String, literal: String, to text: String) -> String {
        let usesCRLF = text.contains("\r\n")
        let normalized = usesCRLF ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        let result = applyToLFNormalized(key: key, literal: literal, to: normalized)
        return usesCRLF ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
    }

    private static func applyToLFNormalized(key: String, literal: String, to text: String) -> String {
        let (table, leaf) = splitKey(key)
        var lines = splitLines(text)

        guard !table.isEmpty else {
            let rootEnd = firstTopLevelHeaderIndex(lines) ?? lines.count
            let leafPattern = "^\\s*\(regexEscaped(leaf))\\s*="
            if let index = firstMatch(lines, in: 0 ..< rootEnd, pattern: leafPattern) {
                lines[index] = replacingValue(in: lines[index], with: literal)
                return join(lines)
            }
            let insertAt = insertionIndex(atEndOf: 0 ..< rootEnd, in: lines)
            lines.insert("\(leaf) = \(literal)", at: insertAt)
            if insertAt + 1 < lines.count, isTopLevelHeaderLine(lines[insertAt + 1]) {
                lines.insert("", at: insertAt + 1)
            }
            return join(lines)
        }

        let rootEnd = firstTopLevelHeaderIndex(lines) ?? lines.count
        let dottedPattern = "^\\s*\(regexEscaped(table))\\.\(regexEscaped(leaf))\\s*="
        if let index = firstMatch(lines, in: 0 ..< rootEnd, pattern: dottedPattern) {
            lines[index] = replacingValue(in: lines[index], with: literal)
            return join(lines)
        }

        guard let headerIndex = firstHeaderIndex(lines, named: table) else {
            return appendingSection(lines, table: table, leaf: leaf, literal: literal)
        }

        let sectionEnd = nextTopLevelHeaderIndex(lines, after: headerIndex) ?? lines.count
        let leafPattern = "^\\s*\(regexEscaped(leaf))\\s*="
        if let index = firstMatch(lines, in: (headerIndex + 1) ..< sectionEnd, pattern: leafPattern) {
            lines[index] = replacingValue(in: lines[index], with: literal)
            return join(lines)
        }
        let insertAt = insertionIndex(atEndOf: (headerIndex + 1) ..< sectionEnd, in: lines)
        lines.insert("\(leaf) = \(literal)", at: insertAt)
        return join(lines)
    }

    /// A brand-new `[table]` section, appended at end of file, separated from
    /// any existing content by exactly one blank line.
    private static func appendingSection(_ lines: [String], table: String, leaf: String, literal: String) -> String {
        var body = lines
        while body.last == "" {
            body.removeLast()
        }
        if !body.isEmpty {
            body.append("")
        }
        body.append("[\(table)]")
        body.append("\(leaf) = \(literal)")
        return join(body)
    }

    /// A bare TOML key's allowed characters (letters, digits, `-`, `_`) — the
    /// only shape `set` ever writes, so any other character in a dot-component
    /// is rejected up front rather than producing an unparseable line.
    private static func isValidBareKeyComponent(_ component: Substring) -> Bool {
        !component.isEmpty && component.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    private static func splitKey(_ key: String) -> (table: String, leaf: String) {
        guard let dotIndex = key.lastIndex(of: ".") else { return ("", key) }
        return (String(key[key.startIndex ..< dotIndex]), String(key[key.index(after: dotIndex)...]))
    }

    private static func splitLines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// The inverse of `splitLines`: a trailing empty element (from a source
    /// that ended in `\n`) reproduces that trailing newline; otherwise one is
    /// added, since every file this writes should end in one.
    private static func join(_ lines: [String]) -> String {
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        return text
    }

    private static func isTopLevelHeaderLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    private static func firstTopLevelHeaderIndex(_ lines: [String]) -> Int? {
        lines.firstIndex(where: isTopLevelHeaderLine)
    }

    private static func nextTopLevelHeaderIndex(_ lines: [String], after index: Int) -> Int? {
        guard index + 1 < lines.count else { return nil }
        return ((index + 1) ..< lines.count).first { isTopLevelHeaderLine(lines[$0]) }
    }

    private static func firstHeaderIndex(_ lines: [String], named name: String) -> Int? {
        let target = "[\(name)]"
        return lines.firstIndex { normalizedHeader($0) == target }
    }

    /// Strips an optional trailing `# comment` and the whitespace just inside
    /// the brackets, so `"[self] # note"` and `"[ self ]"` both normalize to
    /// `"[self]"` and are recognized as the same header `firstHeaderIndex`
    /// looks for.
    private static func normalizedHeader(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if let hashIndex = trimmed.firstIndex(of: "#") {
            trimmed = String(trimmed[..<hashIndex]).trimmingCharacters(in: .whitespaces)
        }
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return trimmed }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return "[\(inner)]"
    }

    private static func firstMatch(_ lines: [String], in range: Range<Int>, pattern: String) -> Int? {
        range.first { lines[$0].range(of: pattern, options: .regularExpression) != nil }
    }

    /// The index to insert at when appending "at the end of" `range`: right
    /// before a trailing empty element that only marks the file's final
    /// newline, so the new line becomes the new last line of content rather
    /// than landing after it.
    private static func insertionIndex(atEndOf range: Range<Int>, in lines: [String]) -> Int {
        if range.upperBound == lines.count, lines.last == "" {
            return lines.count - 1
        }
        return range.upperBound
    }

    private static func regexEscaped(_ value: String) -> String {
        NSRegularExpression.escapedPattern(for: value)
    }

    /// Replaces a matched line's value, keeping everything up to and
    /// including `=` and its following whitespace, and everything after the
    /// old value token (trailing whitespace, an inline `# comment`) verbatim.
    private static func replacingValue(in line: String, with literal: String) -> String {
        guard let equalsRange = line.range(of: "=") else { return line }
        var index = equalsRange.upperBound
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        let prefix = String(line[line.startIndex ..< index])
        let valueEnd = endOfValueToken(in: line, startingAt: index)
        let suffix = String(line[valueEnd...])
        return prefix + literal + suffix
    }

    /// A `"..."` span honors `\`-escapes (so an escaped quote doesn't end the
    /// string early); a `'...'` span does not, since TOML literal strings
    /// have none; otherwise a bare token (a number, bool, date, inline array,
    /// or inline table) runs to whitespace or `#` outside any open `[`/`{`,
    /// or EOL.
    private static func endOfValueToken(in line: String, startingAt start: String.Index) -> String.Index {
        guard start < line.endIndex else { return start }
        switch line[start] {
        case "\"":
            return endOfDoubleQuotedToken(in: line, startingAt: start)
        case "'":
            return endOfSingleQuotedToken(in: line, startingAt: start)
        default:
            return endOfBareToken(in: line, startingAt: start)
        }
    }

    private static func endOfDoubleQuotedToken(in line: String, startingAt start: String.Index) -> String.Index {
        var index = line.index(after: start)
        while index < line.endIndex {
            if line[index] == "\\" {
                index = line.index(after: index)
                if index < line.endIndex {
                    index = line.index(after: index)
                }
                continue
            }
            if line[index] == "\"" {
                return line.index(after: index)
            }
            index = line.index(after: index)
        }
        return index
    }

    private static func endOfSingleQuotedToken(in line: String, startingAt start: String.Index) -> String.Index {
        var index = line.index(after: start)
        while index < line.endIndex, line[index] != "'" {
            index = line.index(after: index)
        }
        return index < line.endIndex ? line.index(after: index) : index
    }

    /// Tracks `[`/`{` nesting depth so embedded whitespace inside a
    /// still-open inline array or table doesn't end the token early.
    private static func endOfBareToken(in line: String, startingAt start: String.Index) -> String.Index {
        var index = start
        var depth = 0
        while index < line.endIndex {
            let character = line[index]
            if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth = max(0, depth - 1)
            } else if depth == 0, character == " " || character == "\t" || character == "#" {
                break
            }
            index = line.index(after: index)
        }
        return index
    }
}
