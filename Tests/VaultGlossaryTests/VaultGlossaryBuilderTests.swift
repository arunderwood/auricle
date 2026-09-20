import Core
import Foundation
import Testing
@testable import VaultGlossary

// MARK: - Categorization

@Test func standardVaultFoldersCategorizePages() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben Smith.md")
    try fixture.note("Projects/chicken-palace.md")
    try fixture.note("Concepts/packet radio.md")

    let glossary = try fixture.builder().build().glossary

    #expect(glossary.people == ["Ben Smith"])
    #expect(glossary.projects == ["chicken-palace"])
    #expect(glossary.concepts == ["packet radio"])
    #expect(glossary.uncategorized.isEmpty)
}

@Test func folderNamesMatchCaseInsensitivelyAndNestedFoldersToo() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("people/Ada.md")
    try fixture.note("Work/PROJECTS/Auricle.md")
    try fixture.note("Projects/People/Priya.md")

    let glossary = try fixture.builder().build().glossary

    #expect(glossary.people == ["Ada", "Priya"])
    #expect(glossary.projects == ["Auricle"])
}

@Test func aGhostLinkBecomesAnUncategorizedTerm() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("Ideas.md", "Try [[meshcore]] on the roof.")

    let glossary = try fixture.builder().build().glossary

    #expect(glossary.uncategorized.contains("meshcore"))
    #expect(glossary.uncategorized.contains("Ideas"))
}

@Test func aVaultWithoutTheStandardFoldersPutsEveryTermInUncategorized() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("Notes/Ben.md", "Works on [[chicken-palace]].")
    try fixture.note("Misc/packet radio.md")

    let glossary = try fixture.builder().build().glossary

    #expect(glossary.people.isEmpty)
    #expect(glossary.projects.isEmpty)
    #expect(glossary.concepts.isEmpty)
    #expect(glossary.uncategorized == ["Ben", "chicken-palace", "packet radio"])
}

@Test func aPageNameKeepsItsCategoryWhenALinkNamesTheSameTermInAnotherCase() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben Smith.md")
    try fixture.note("Other.md", "See [[ben smith]] and [[BEN SMITH]].")

    let glossary = try fixture.builder().build().glossary

    #expect(glossary.people == ["Ben Smith"])
    #expect(!glossary.uncategorized.contains { $0.lowercased() == "ben smith" })
}

@Test func termsAreDeduplicatedCaseInsensitivelySortedAndStoredWithoutBrackets() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("a.md", "[[zebra]] [[Apple]] [[apple]] [[Mango]]")

    let uncategorized = try fixture.builder().build().glossary.uncategorized

    #expect(uncategorized == ["a", "Apple", "Mango", "zebra"])
    #expect(!uncategorized.contains { $0.contains("[") || $0.contains("]") })
}

@Test func linkAliasHeadingBlockAndFolderPathReduceToTheTarget() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("n.md", """
    [[alpha|an alias]] [[bravo#Some heading]] [[charlie^block1]] [[People/Delta Person]]
    [[echo\\|table alias]] [[#same note heading]] [[ foxtrot ]]
    """)

    let terms = try fixture.builder().build().glossary.uncategorized

    #expect(terms == ["alpha", "bravo", "charlie", "Delta Person", "echo", "foxtrot", "n"])
}

@Test func anUnclosedOrMultilineLinkIsIgnoredAndTheTextAfterItStillScans() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("n.md", "[[never closed\nnext line [[good]] and [[broken\nline]] [[[nested]] tail")

    let terms = try fixture.builder().build().glossary.uncategorized

    #expect(terms.contains("good"))
    #expect(terms.contains("nested"))
    #expect(!terms.contains { $0.contains("never") || $0.contains("broken") })
}

// MARK: - Skips

@Test func hiddenEntriesTheMeetingsSubdirDateNamedPagesAndSymlinkedDirectoriesAreSkipped() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("Kept.md", "[[linked-from-kept]]")
    try fixture.note(".obsidian/Config.md", "[[hidden-link]]")
    try fixture.note(".trash/Deleted.md")
    try fixture.note(".git/Ignored.md")
    try fixture.note("Meetings/Weekly sync.md", "[[from-a-meeting-note]]")
    try fixture.note("Nested/Meetings/Kept Because Not Top Level.md")
    try fixture.note("2026-09-18.md", "[[from-a-daily-note]]")
    try fixture.note("2026-09-18 Standup.md")
    try fixture.note("Ref.md", "[[2026-09-18]] [[2026-09-18 Standup]]")

    let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try fixture.writeFile("[[from-outside]]", to: outside.appendingPathComponent("Outside Page.md"))
    try FileManager.default.createSymbolicLink(at: fixture.vault.appendingPathComponent("Linked"), withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(at: fixture.vault.appendingPathComponent("loop"), withDestinationURL: fixture.vault)

    let terms = try fixture.builder().build().glossary.uncategorized

    #expect(terms == ["Kept", "Kept Because Not Top Level", "linked-from-kept", "Ref"])
}

@Test func aCustomMeetingsSubdirIsSkippedInsteadOfTheDefault() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("Meetings/Weekly.md")
    try fixture.note("Work/Calls/Sync.md")

    let terms = try fixture.builder(meetingsSubdir: "Work/Calls").build().glossary.uncategorized

    #expect(terms == ["Weekly"])
}

// MARK: - Cache

@Test func aSecondBuildOfAnUnchangedVaultReusesTheCache() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md", "[[meshcore]]")

    let first = try fixture.builder().build()
    let second = try fixture.builder().build()

    #expect(first.rebuilt)
    #expect(!second.rebuilt)
    #expect(second.glossary == first.glossary)
}

@Test func theCacheIsOwnerOnlySnakeCaseJSONWithASchemaVersion() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md")

    _ = try fixture.builder().build()

    let data = try Data(contentsOf: fixture.cacheFile)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["schema_version"] as? Int == 1)
    #expect(json["vault_path"] is String)
    let fingerprint = try #require(json["fingerprint"] as? [String: Any])
    #expect(fingerprint["entry_count"] as? Int == 2)
    #expect(fingerprint["newest_modification"] is Double)
    #expect(json["glossary"] is [String: Any])
    let permissions = try FileManager.default.attributesOfItem(atPath: fixture.cacheFile.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func aNewerFileModificationDateRescans() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md")
    _ = try fixture.builder().build()

    try fixture.setModificationDate(Date().addingTimeInterval(120), of: "People/Ben.md")
    let third = try fixture.builder().build()
    let fourth = try fixture.builder().build()

    #expect(third.rebuilt)
    #expect(!fourth.rebuilt)
}

@Test func aNewerDirectoryModificationDateRescans() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md")
    _ = try fixture.builder().build()

    try fixture.setModificationDate(Date().addingTimeInterval(120), of: "People")

    #expect(try fixture.builder().build().rebuilt)
}

@Test func aLinkAddedInsideAnExistingNoteIsPickedUpOnTheNextBuild() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("Ideas.md", "nothing yet")
    let before = try fixture.builder().build()
    #expect(!before.glossary.uncategorized.contains("meshcore"))

    try fixture.note("Ideas.md", "now [[meshcore]]")
    try fixture.setModificationDate(Date().addingTimeInterval(120), of: "Ideas.md")
    let after = try fixture.builder().build()

    #expect(after.rebuilt)
    #expect(after.glossary.uncategorized.contains("meshcore"))
}

@Test func aRemovedEntryRescansEvenWhenEveryDateIsRestored() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md")
    try fixture.note("People/Ada.md")
    let directoryDate = try fixture.modificationDate(of: "People")
    let rootDate = try fixture.modificationDate(of: "")
    _ = try fixture.builder().build()

    try FileManager.default.removeItem(at: fixture.vault.appendingPathComponent("People/Ada.md"))
    try fixture.setModificationDate(directoryDate, of: "People")
    try fixture.setModificationDate(rootDate, of: "")
    let rebuilt = try fixture.builder().build()

    #expect(rebuilt.rebuilt)
    #expect(rebuilt.glossary.people == ["Ben"])
}

@Test func aCorruptCacheRescans() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md")
    _ = try fixture.builder().build()

    try fixture.writeFile("{ not json", to: fixture.cacheFile)
    let outcome = try fixture.builder().build()

    #expect(outcome.rebuilt)
    #expect(outcome.glossary.people == ["Ben"])
    #expect(try !(fixture.builder().build().rebuilt))
}

@Test func aCacheFromAnotherSchemaVersionRescans() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md")
    _ = try fixture.builder().build()

    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cacheFile)) as? [String: Any])
    json["schema_version"] = 0
    try fixture.overwrite(fixture.cacheFile, with: JSONSerialization.data(withJSONObject: json))

    #expect(try fixture.builder().build().rebuilt)
}

@Test func aCacheBuiltForAnotherVaultPathRescans() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md")
    _ = try fixture.builder().build()

    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cacheFile)) as? [String: Any])
    json["vault_path"] = fixture.base.appendingPathComponent("some-other-vault").path
    try fixture.overwrite(fixture.cacheFile, with: JSONSerialization.data(withJSONObject: json))

    #expect(try fixture.builder().build().rebuilt)
}

@Test func aCacheWriteFailureIsSwallowedAndTheGlossaryStillReturns() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md")
    let blocker = fixture.base.appendingPathComponent("blocker")
    try fixture.writeFile("a file, not a directory", to: blocker)
    let builder = VaultGlossaryBuilder(vaultPath: fixture.vault, cacheRoot: blocker.appendingPathComponent("cache"))

    let outcome = try builder.build()

    #expect(outcome.glossary.people == ["Ben"])
    #expect(outcome.rebuilt)
}

// MARK: - Failure

@Test func aVaultPathThatIsNotADirectoryThrowsVaultPathMissing() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    let missing = VaultGlossaryBuilder(vaultPath: fixture.base.appendingPathComponent("nope"), cacheRoot: fixture.cacheRoot)
    let aFile = fixture.base.appendingPathComponent("plain.txt")
    try fixture.writeFile("x", to: aFile)

    #expect(throws: VaultGlossaryError.vaultPathMissing) { try missing.build() }
    #expect(throws: VaultGlossaryError.vaultPathMissing) { try VaultGlossaryBuilder(vaultPath: aFile, cacheRoot: fixture.cacheRoot).build() }
}

@Test func buildOrEmptyReturnsAnEmptyGlossaryAndReportsTheReason() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    let missing = VaultGlossaryBuilder(vaultPath: fixture.base.appendingPathComponent("nope"), cacheRoot: fixture.cacheRoot)
    var reported: [VaultGlossaryError] = []

    let glossary = missing.buildOrEmpty { reported.append($0) }

    #expect(glossary == Glossary())
    #expect(reported == [.vaultPathMissing])
}

@Test func buildOrEmptyReturnsTheGlossaryOfAReadableVaultWithoutReporting() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    try fixture.note("People/Ben.md")
    var reported: [VaultGlossaryError] = []

    let glossary = fixture.builder().buildOrEmpty { reported.append($0) }

    #expect(glossary.people == ["Ben"])
    #expect(reported.isEmpty)
}

@Test func anUnreadableVaultDirectoryThrowsVaultUnreadable() throws {
    guard getuid() != 0 else { return }
    let fixture = try VaultFixture()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.vault.path)
        fixture.cleanUp()
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.vault.path)

    #expect(throws: VaultGlossaryError.vaultUnreadable) { try fixture.builder().build() }
}

// MARK: - Scale

@Test func aTenThousandFileVaultBuildsWithinTheBoundAndThenReusesTheCache() throws {
    let fixture = try VaultFixture()
    defer { fixture.cleanUp() }
    for folder in 0 ..< 100 {
        let directory = fixture.vault.appendingPathComponent("Topic \(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in 0 ..< 100 {
            let id = folder * 100 + file
            try fixture.writeFile("See [[ghost-\(id)]] and [[Page \(id)|alias]].", to: directory.appendingPathComponent("Page \(id).md"))
        }
    }

    let clock = ContinuousClock()
    var outcome: VaultGlossaryBuilder.Outcome?
    let elapsed = try clock.measure { outcome = try fixture.builder().build() }

    // Catches a super-linear scan, not a slow machine: an unloaded debug build takes about 4 s,
    // and a shared CI runner running the whole suite in parallel has taken 12 s.
    #expect(elapsed < .seconds(60))
    let built = try #require(outcome)
    #expect(built.rebuilt)
    #expect(built.glossary.uncategorized.count == 20000)
    #expect(try !fixture.builder().build().rebuilt)
}
