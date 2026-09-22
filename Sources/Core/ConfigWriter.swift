import Foundation
import TOMLKit

/// Edits a single key in `~/.auricle/config.toml` (FR59) by rewriting the raw
/// file text, not by parsing the document into a `TOMLTable` and
/// reserializing it. `TOMLKit`'s backend discards comment tokens while
/// parsing (`consume_comment()` in its vendored `toml.hpp`) and nothing in
/// its node model stores them, so a parse/mutate/reserialize round trip would
/// silently delete every comment in a file this app promises is safe to
/// hand-edit. `TOMLKit` is still used, but only to render the one new value
/// as a correctly escaped TOML literal.
///
/// Only two existing representations of a nested key are recognized: a
/// fully-dotted line (`table.leaf = ...`) at the root, or a `[table]`
/// section. A table already defined only in inline-table form
/// (`table = { leaf = ... }`) is not detected, so `set` appends a fresh
/// `[table]` section alongside it rather than editing it in place.
public enum ConfigWriter {
    public enum WriterError: Error, Sendable, Equatable {
        /// `key` is empty, exactly `"."`, or starts or ends with `.`.
        case invalidKey(key: String)
        /// The existing file's contents are not valid UTF-8.
        case malformed

        public var message: String {
            switch self {
            case let .invalidKey(key):
                "\"\(key)\" is not a valid config key."
            case .malformed:
                "the existing config file is not valid UTF-8."
            }
        }
    }

    /// `fileURL`/`homeDirectory` mirror `Config.load`'s own test-seam
    /// parameters, so a caller passing neither writes exactly where
    /// `Config.load` reads, and a test never touches the real `~/.auricle`.
    public static func set(
        _ key: String,
        to value: String,
        fileURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    ) throws {
        guard !key.isEmpty, !key.hasPrefix("."), !key.hasSuffix(".") else {
            throw WriterError.invalidKey(key: key)
        }
        guard key.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isValidBareKeyComponent) else {
            throw WriterError.invalidKey(key: key)
        }

        let url = fileURL ?? Config.defaultFileURL(homeDirectory: homeDirectory)
        let existingText = try readExistingText(at: url)
        let literal = formattedLiteral(for: value)
        let updatedText = apply(key: key, literal: literal, to: existingText)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWriter.write(Data(updatedText.utf8), to: url)
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

    /// `options: []` disables `.allowLiteralStrings`, so a value that would
    /// otherwise render as a single-quoted TOML literal always renders as a
    /// double-quoted basic string, matching what `replacingValue` expects to
    /// find on a later edit.
    private static func formattedLiteral(for value: String) -> String {
        let rendered = TOMLTable(["v": value]).convert(to: .toml, options: [])
        let prefix = "v = "
        var literal = rendered.hasPrefix(prefix) ? String(rendered.dropFirst(prefix.count)) : rendered
        while literal.hasSuffix("\n") {
            literal.removeLast()
        }
        return literal
    }

    private static func apply(key: String, literal: String, to text: String) -> String {
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
