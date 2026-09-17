import Yams

/// Turns a `MeetingForFrontmatter` into the complete vault note markdown:
/// YAML frontmatter (Decision 2.2's schema, emitted via Yams so arbitrary
/// calendar-event titles never need hand-written escaping) followed by the
/// fixed body section order (FR37).
public enum FrontmatterRenderer {
    public static func render(meeting: MeetingForFrontmatter) -> String {
        "---\n\(renderFrontmatter(meeting))---\n\n\(renderBody(meeting))\n"
    }

    // MARK: - Frontmatter

    private static func renderFrontmatter(_ meeting: MeetingForFrontmatter) -> String {
        var tags = ["auricle/meeting"]
        if meeting.needsAttribution {
            tags.append("auricle/needs-attribution")
        }
        if meeting.needsCalendarEnrichment {
            tags.append("auricle/needs-calendar-enrichment")
        }

        var auricleFields: [(Node, Node)] = [
            (plainScalar("meeting_id"), quotedScalar(meeting.meetingID.rawValue)),
            (plainScalar("schema_version"), plainScalar(String(meeting.schemaVersion))),
        ]
        if let supersedes = meeting.supersedes {
            auricleFields.append((plainScalar("supersedes"), quotedScalar(supersedes)))
        }

        let mapping = Node.mapping(Node.Mapping([
            (plainScalar("title"), quotedScalar(meeting.title)),
            (plainScalar("date"), plainScalar(meeting.date)),
            (plainScalar("tags"), Node.sequence(Node.Sequence(tags.map(plainScalar), .implicit, .block))),
            (plainScalar("attendees"), Node.sequence(Node.Sequence(meeting.attendees.map(quotedScalar), .implicit, .block))),
            (plainScalar("auricle"), Node.mapping(Node.Mapping(auricleFields, .implicit, .block))),
        ], .implicit, .block))

        // Hand-built from plain Swift strings with an explicit style on every
        // scalar, so this can never hit a YamlError: the failure modes
        // `serialize(node:)` documents (unrepresentable emitter state) don't
        // arise from a fixed-shape mapping of caller-supplied strings. The
        // `do/catch` (rather than `try!`) keeps this file clean under the
        // repo's default `force_try` lint rule while still letting
        // `render(meeting:)` expose a non-throwing signature to its callers.
        do {
            let yaml = try Yams.serialize(
                node: mapping,
                indent: 2,
                width: -1,
                allowUnicode: true,
                sequenceStyle: .block,
                mappingStyle: .block,
            )
            return indentTopLevelSequenceItems(yaml)
        } catch {
            fatalError("FrontmatterRenderer: Yams failed to serialize a fixed-shape frontmatter mapping: \(error)")
        }
    }

    /// libyaml emits a block sequence that's a mapping value flush with its
    /// key ("tags:\n- x") rather than indented under it — a documented
    /// libyaml behavior (`emitter.c`'s `indentless` block-sequence branch)
    /// with no public emitter flag to disable. `tags` and `attendees` are
    /// this renderer's only sequences, and both hold only scalars, so
    /// indenting every column-0 "- " line by the block's own indent width
    /// reproduces Decision 2.2's nested-list shape without a general-purpose
    /// (and riskier) YAML reformatter.
    private static func indentTopLevelSequenceItems(_ yaml: String) -> String {
        yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("- ") ? "  \($0)" : String($0) }
            .joined(separator: "\n")
    }

    private static func plainScalar(_ string: String) -> Node {
        .scalar(Node.Scalar(string, .implicit, .plain))
    }

    private static func quotedScalar(_ string: String) -> Node {
        .scalar(Node.Scalar(string, .implicit, .doubleQuoted))
    }

    // MARK: - Body

    private static func renderBody(_ meeting: MeetingForFrontmatter) -> String {
        [
            meeting.summary,
            renderQuotedItemSection(heading: "Action Items", items: meeting.actionItems),
            renderQuotedItemSection(heading: "Decisions", items: meeting.decisions),
            renderTranscriptSection(meeting.transcriptSegments),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func renderQuotedItemSection(heading: String, items: [QuotedItem]) -> String {
        guard !items.isEmpty else { return "## \(heading)" }
        let bullets = items
            .map { "- \($0.text)\n  > \($0.quote)" }
            .joined(separator: "\n")
        return "## \(heading)\n\n\(bullets)"
    }

    private static func renderTranscriptSection(_ segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "## Transcript" }
        let paragraphs = segments
            .map { "**\($0.speaker):** \($0.text)" }
            .joined(separator: "\n\n")
        return "## Transcript\n\n\(paragraphs)"
    }
}
