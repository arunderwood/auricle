import Testing
import TestSupport

@Test func topLevelHeaderIsFlaggedAndASectionHeaderIsClean() {
    let violating = "# Meeting Title\n\nBody text."
    #expect(MarkdownDisciplineChecker.check(violating) == [
        MarkdownDisciplineChecker.Violation(kind: .topLevelHeader, line: 1),
    ])

    let clean = "## Summary\n\nBody text."
    #expect(MarkdownDisciplineChecker.check(clean).isEmpty)
}

@Test func headerBeyondThreeHashesIsFlaggedAndAThreeHashHeaderIsClean() {
    let violating = "#### Too Deep\n"
    #expect(MarkdownDisciplineChecker.check(violating) == [
        MarkdownDisciplineChecker.Violation(kind: .headerTooDeep, line: 1),
    ])

    let clean = "### Action Items\n"
    #expect(MarkdownDisciplineChecker.check(clean).isEmpty)
}

@Test func indentedTopLevelHeaderIsStillFlagged() {
    let violating = "   # Meeting Title\n\nBody text."
    #expect(MarkdownDisciplineChecker.check(violating) == [
        MarkdownDisciplineChecker.Violation(kind: .topLevelHeader, line: 1),
    ])

    let clean = "  ## Summary\n\nBody text."
    #expect(MarkdownDisciplineChecker.check(clean).isEmpty)
}

@Test func emojiIsFlaggedAndPlainPunctuationIsClean() {
    let violating = "## Summary\n\n🤖 Reviewed 3 segments."
    #expect(MarkdownDisciplineChecker.check(violating) == [
        MarkdownDisciplineChecker.Violation(kind: .emoji, line: 3),
    ])

    let clean = "## Summary\n\nReviewed 3 segments (#3 of 5)."
    #expect(MarkdownDisciplineChecker.check(clean).isEmpty)
}

@Test func horizontalRuleOutsideFrontmatterIsFlaggedAndTheFrontmatterFenceIsClean() {
    let violating = "## Summary\n\n---\n\nMore body text."
    #expect(MarkdownDisciplineChecker.check(violating) == [
        MarkdownDisciplineChecker.Violation(kind: .horizontalRuleOutsideFrontmatter, line: 3),
    ])

    let clean = "---\nauricle:\n  meeting_id: 01ARZ3NDEKTSV4RRFFQ69G5FAV\n---\n\n## Summary\n\nBody text."
    #expect(MarkdownDisciplineChecker.check(clean).isEmpty)
}

@Test func tableIsFlaggedAndABulletListIsClean() {
    let violating = "## Attendees\n\n| Name | Role |\n| --- | --- |\n| Ada | Host |"
    #expect(MarkdownDisciplineChecker.check(violating) == [
        MarkdownDisciplineChecker.Violation(kind: .table, line: 4),
    ])

    let clean = "## Attendees\n\n- Ada — Host\n- Grace — Attendee"
    #expect(MarkdownDisciplineChecker.check(clean).isEmpty)
}
