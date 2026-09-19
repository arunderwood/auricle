import Foundation

/// Finds the pages a note links to. A byte scan, not a regular expression: a
/// large vault is tens of megabytes of text and a rescan reads all of it.
enum WikilinkScanner {
    /// The target of every `[[...]]` in a UTF-8 text, reduced to the bare page
    /// name: the alias (`|`), heading (`#`), block (`^`) and folder path are
    /// dropped, so `[[People/Ben Smith#Bio|Ben]]` names `Ben Smith`. A link
    /// cannot span a line or hold a bracket, so an unclosed `[[` is skipped
    /// rather than swallowing the text after it.
    static func targets(in data: Data) -> [String] {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var targets: [String] = []
            var index = 0
            while index + 1 < bytes.count {
                guard bytes[index] == 0x5B, bytes[index + 1] == 0x5B else {
                    index += 1
                    continue
                }
                guard let close = closingBrackets(in: bytes, from: index + 2) else {
                    index += 1
                    continue
                }
                if
                    let inner = String(bytes: bytes[(index + 2) ..< close], encoding: .utf8),
                    let target = bareTarget(of: inner) {
                    targets.append(target)
                }
                index = close + 2
            }
            return targets
        }
    }

    /// `YYYY-MM-DD` at the start of a name: daily notes and dated meeting
    /// notes, which are about a day, not a term.
    static func isDateNamed(_ name: String) -> Bool {
        let bytes = Array(name.utf8.prefix(10))
        guard bytes.count == 10 else { return false }
        for (offset, byte) in bytes.enumerated() {
            let isSeparator = offset == 4 || offset == 7
            let isExpected = isSeparator ? byte == 0x2D : (0x30 ... 0x39).contains(byte)
            if !isExpected {
                return false
            }
        }
        return true
    }

    /// Where the `]]` that closes a link opened before `start` begins, `nil`
    /// when a newline, a `[` or a lone `]` comes first.
    private static func closingBrackets(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var cursor = start
        while cursor + 1 < bytes.count {
            switch bytes[cursor] {
            case 0x0A, 0x5B:
                return nil
            case 0x5D:
                return bytes[cursor + 1] == 0x5D ? cursor : nil
            default:
                cursor += 1
            }
        }
        return nil
    }

    private static func bareTarget(of link: String) -> String? {
        var target = Substring(link)
        for separator: Character in ["|", "#", "^"] {
            if let cut = target.firstIndex(of: separator) {
                target = target[..<cut]
            }
        }
        var text = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("\\") {
            text.removeLast()
        }
        if let slash = text.lastIndex(of: "/") {
            text = String(text[text.index(after: slash)...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isDateNamed(text) else { return nil }
        return text
    }
}
