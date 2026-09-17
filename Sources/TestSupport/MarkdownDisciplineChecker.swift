import Foundation

/// A pure, renderer-independent validator for AR-PAT-9 (architecture.md's
/// Markdown Output rules): a vault note's section headers stay within `## `
/// through `### ` (the filename owns the document's `# ` title; Obsidian's
/// outline stays shallow by deliberate constraint), no emoji, no horizontal
/// rule outside the YAML frontmatter fence, no table (Obsidian renders
/// tables inconsistently across themes).
///
/// Markdown string in, violations out — no dependency on any renderer, so
/// this ships ahead of one existing. `FrontmatterRenderer` (Epic 2) becomes
/// this checker's first real caller, via `FrontmatterRendererTests.swift`.
public enum MarkdownDisciplineChecker {
    public enum ViolationKind: Sendable, Equatable {
        /// A `# ` (single-hash) header — the filename, not the body, owns
        /// the document's title.
        case topLevelHeader
        /// A header beyond `### ` (four or more hashes).
        case headerTooDeep
        case emoji
        case horizontalRuleOutsideFrontmatter
        case table
    }

    public struct Violation: Sendable, Equatable {
        public let kind: ViolationKind
        /// 1-based, matching the line an editor would report.
        public let line: Int

        public init(kind: ViolationKind, line: Int) {
            self.kind = kind
            self.line = line
        }
    }

    /// Every violation found, in line order. An empty result means `markdown`
    /// is clean.
    public static func check(_ markdown: String) -> [Violation] {
        let lines = markdown.components(separatedBy: "\n")
        let frontmatterRange = frontmatterLineRange(lines)
        var violations: [Violation] = []

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            let insideFrontmatter = frontmatterRange?.contains(lineNumber) ?? false

            if let depth = headerDepth(of: line) {
                if depth == 1 {
                    violations.append(Violation(kind: .topLevelHeader, line: lineNumber))
                } else if depth > 3 {
                    violations.append(Violation(kind: .headerTooDeep, line: lineNumber))
                }
            }

            if containsEmoji(line) {
                violations.append(Violation(kind: .emoji, line: lineNumber))
            }

            if !insideFrontmatter, isHorizontalRule(line) {
                violations.append(Violation(kind: .horizontalRuleOutsideFrontmatter, line: lineNumber))
            }

            if !insideFrontmatter, isTableDelimiterRow(line) {
                violations.append(Violation(kind: .table, line: lineNumber))
            }
        }

        return violations
    }

    // MARK: - Frontmatter

    /// The 1-based line range a `---`-fenced frontmatter block occupies,
    /// including both fence lines — `nil` when the document doesn't open
    /// with one. Only an *opening* fence at line 1 with a matching close
    /// counts; a bare `---` anywhere else is a horizontal rule, not
    /// frontmatter, per Decision 2.2's fixed position for the block.
    private static func frontmatterLineRange(_ lines: [String]) -> ClosedRange<Int>? {
        guard lines.first == "---", lines.count > 1 else { return nil }
        for offset in 1 ..< lines.count where lines[offset] == "---" {
            return 1 ... (offset + 1)
        }
        return nil
    }

    // MARK: - Headers

    /// The number of leading `#` characters when they form a valid ATX
    /// heading (1-6 hashes followed by a space or end of line, per
    /// CommonMark) — `nil` for any other line, including `#hashtag`-style
    /// text with no following space. Up to 3 leading spaces of indentation
    /// are skipped first, since CommonMark still treats those as a heading;
    /// 4 or more makes it an indented code block instead, so this stops
    /// skipping at 3.
    private static func headerDepth(of line: String) -> Int? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, leadingSpaces < 3, line[index] == " " {
            leadingSpaces += 1
            index = line.index(after: index)
        }

        var count = 0
        while index < line.endIndex, count < 6, line[index] == "#" {
            count += 1
            index = line.index(after: index)
        }
        guard count > 0 else { return nil }
        guard index == line.endIndex || line[index] == " " else { return nil }
        return count
    }

    // MARK: - Emoji

    private static func containsEmoji(_ line: String) -> Bool {
        line.contains { character in
            guard let firstScalar = character.unicodeScalars.first else { return false }
            // A multi-scalar grapheme (ZWJ sequences, flags, skin-tone
            // modifiers) is emoji whenever its first scalar is
            // emoji-eligible. A single scalar only counts when it defaults
            // to emoji *presentation* — excludes plain digits/punctuation
            // that are merely emoji-eligible as a keycap base (e.g. "3",
            // "#") without the combining keycap actually present.
            if character.unicodeScalars.count > 1 {
                return firstScalar.properties.isEmoji
            }
            return firstScalar.properties.isEmojiPresentation
        }
    }

    // MARK: - Horizontal rules

    /// A CommonMark thematic break: three or more of the same `-`/`*`/`_`
    /// character, optionally space-separated, and nothing else on the line.
    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let withoutInteriorSpaces = trimmed.filter { $0 != " " }
        guard withoutInteriorSpaces.count >= 3 else { return false }
        for marker: Character in ["-", "*", "_"] where withoutInteriorSpaces.allSatisfy({ $0 == marker }) {
            return true
        }
        return false
    }

    // MARK: - Tables

    /// A GFM table delimiter row (`| --- | :---: |`) — the unambiguous
    /// signal that a table exists, independent of exactly how many header/
    /// body rows surround it.
    private static func isTableDelimiterRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = line
            .trimmingCharacters(in: .whitespaces)
            .split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmedCell = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmedCell.isEmpty else { return false }
            return trimmedCell.contains("-") && trimmedCell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
