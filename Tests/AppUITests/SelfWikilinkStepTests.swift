@testable import AppUI
import Core
import Foundation
import Testing
import VaultGlossary

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A model already past the vault picker, so every test starts on `.selfWikilink`.
/// Nothing here writes the real config file or Keychain: every write closure is
/// a no-op unless the test passes its own.
@MainActor
private func makeModel(
    vaultDirectory: URL,
    configuredSelfWikilink: String? = nil,
    fullUserName: String = "Jordan Lee",
    writeVaultPath: @escaping @Sendable (URL) throws -> Void = { _ in },
    writeSelfWikilink: @escaping @Sendable (String) throws -> Void = { _ in },
    vaultTerms: @escaping @Sendable (URL) async -> Glossary = { _ in Glossary() },
) throws -> OnboardingConfigureModel {
    let model = OnboardingConfigureModel(
        opener: { _ in true },
        validateVaultPath: { _ in },
        writeVaultPath: writeVaultPath,
        writeAPIKey: { _ in },
        configuredVaultPath: { nil },
        writeSelfWikilink: writeSelfWikilink,
        configuredSelfWikilink: { configuredSelfWikilink },
        fullUserName: fullUserName,
        vaultTerms: vaultTerms,
    )
    try model.selectVaultPath(vaultDirectory)
    return model
}

@MainActor
struct SelfWikilinkPrefillTests {
    private let vault = FileManager.default.temporaryDirectory

    @Test func prefillsTheFullUserNameAsAWikilink() throws {
        let model = try makeModel(vaultDirectory: vault, fullUserName: "Jordan Lee")
        #expect(model.subStep == .selfWikilink)
        #expect(model.selfWikilinkText == "[[Jordan Lee]]")
    }

    @Test func prefersTheConfiguredValue() throws {
        let model = try makeModel(vaultDirectory: vault, configuredSelfWikilink: "[[Me]]", fullUserName: "Jordan Lee")
        #expect(model.selfWikilinkText == "[[Me]]")
    }

    @Test("A blank full name prefills nothing", arguments: ["", "   ", "\n\t"])
    func blankFullNamePrefillsEmpty(fullUserName: String) throws {
        let model = try makeModel(vaultDirectory: vault, fullUserName: fullUserName)
        #expect(model.selfWikilinkText.isEmpty)
    }

    @Test func defaultStripsLinkSyntaxCharacters() {
        #expect(OnboardingConfigureModel.defaultSelfWikilink(fullUserName: #"Jo[r]d|a#n^ \Lee"#) == "[[Jordan Lee]]")
        #expect(OnboardingConfigureModel.defaultSelfWikilink(fullUserName: "[]|#^") == "")
    }
}

@MainActor
struct SelfWikilinkConfirmTests {
    private let vault = FileManager.default.temporaryDirectory

    @Test("Bare or wrapped text is stored as one wikilink", arguments: [
        ("Jordan", "[[Jordan]]"),
        ("  [[Jordan]]  ", "[[Jordan]]"),
        ("[[ Jordan Lee ]]", "[[Jordan Lee]]"),
    ])
    func acceptedTextIsStoredWrappedAndAdvances(text: String, stored: String) throws {
        let model = try makeModel(vaultDirectory: vault)
        model.selfWikilinkText = text
        try model.confirmSelfWikilink()
        #expect(model.selfWikilink == stored)
        #expect(model.selfWikilinkText == stored)
        #expect(model.selfWikilinkError == nil)
        #expect(model.subStep == .obsidian)
    }

    @Test("Empty text is refused", arguments: ["", "   ", "[[ ]]", "[[]]"])
    func emptyTextStaysAndThrows(text: String) throws {
        let model = try makeModel(vaultDirectory: vault)
        model.selfWikilinkText = text
        #expect(throws: SelfWikilinkError.empty) {
            try model.confirmSelfWikilink()
        }
        #expect(model.selfWikilinkError == .empty)
        #expect(model.selfWikilink == nil)
        #expect(model.subStep == .selfWikilink)
    }

    @Test("Link syntax and stray brackets are refused", arguments: [
        "[[Jo]]n]]", "Jo[n", "[[Jordan", "Jordan]]", "[[[Jordan]]]",
        "[[Jordan Lee|Jordan]]", "[[|me]]", "[[Jordan|]]", "[[Jo\n]]", "[[Name#Heading]]", "Jo^n", "a\\b",
    ])
    func strayBracketsStayAndThrow(text: String) throws {
        let model = try makeModel(vaultDirectory: vault)
        model.selfWikilinkText = text
        #expect(throws: SelfWikilinkError.malformed) {
            try model.confirmSelfWikilink()
        }
        #expect(model.selfWikilinkError == .malformed)
        #expect(model.selfWikilink == nil)
        #expect(model.subStep == .selfWikilink)
    }

    @Test func aSuccessfulConfirmClearsAnEarlierError() throws {
        let model = try makeModel(vaultDirectory: vault)
        model.selfWikilinkText = ""
        #expect(throws: SelfWikilinkError.empty) {
            try model.confirmSelfWikilink()
        }
        model.selfWikilinkText = "Jordan"
        try model.confirmSelfWikilink()
        #expect(model.selfWikilinkError == nil)
    }
}

@MainActor
struct SelfWikilinkSuggestionTests {
    private let vault = FileManager.default.temporaryDirectory

    @Test func suggestsFromARealVaultPrefixFirstAndPeopleFirst() async throws {
        let vaultDirectory = try makeTemporaryDirectory()
        let cacheRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: vaultDirectory)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        let people = vaultDirectory.appendingPathComponent("People", isDirectory: true)
        try FileManager.default.createDirectory(at: people, withIntermediateDirectories: true)
        try AtomicWriter.write(Data("# Jordan Lee\n".utf8), to: people.appendingPathComponent("Jordan Lee.md"))
        try AtomicWriter.write(Data("Food notes\n".utf8), to: vaultDirectory.appendingPathComponent("Jordanian Food.md"))
        try AtomicWriter.write(Data("Other notes\n".utf8), to: vaultDirectory.appendingPathComponent("Other.md"))

        let model = try makeModel(vaultDirectory: vaultDirectory, vaultTerms: { url in
            VaultGlossaryBuilder(vaultPath: url, cacheRoot: cacheRoot).buildOrEmpty()
        })
        await model.loadVaultTerms()
        model.selfWikilinkText = "jord"

        #expect(model.selfWikilinkSuggestions == ["Jordan Lee", "Jordanian Food"])
    }

    @Test func prefixMatchesComeBeforeSubstringMatchesWithinAGroup() async throws {
        let model = try makeModel(vaultDirectory: vault, vaultTerms: { _ in
            Glossary(people: ["Bo Jordanson", "Ajordan", "Lee Jordan"])
        })
        await model.loadVaultTerms()
        model.selfWikilinkText = "jord"
        #expect(model.selfWikilinkSuggestions == ["Bo Jordanson", "Lee Jordan", "Ajordan"])
    }

    @Test func peopleComeBeforeUncategorizedAndProjectsAndConceptsAreLeftOut() async throws {
        let model = try makeModel(vaultDirectory: vault, vaultTerms: { _ in
            Glossary(
                people: ["Ajordan"],
                projects: ["Jordan Project"],
                concepts: ["Jordan Concept"],
                uncategorized: ["Jordan Notes"],
            )
        })
        await model.loadVaultTerms()
        model.selfWikilinkText = "[[jord"
        #expect(model.selfWikilinkSuggestions == ["Ajordan", "Jordan Notes"])
    }

    @Test func atMostFiveSuggestions() async throws {
        let model = try makeModel(vaultDirectory: vault, vaultTerms: { _ in
            Glossary(people: (1 ... 8).map { "Jordan \($0)" })
        })
        await model.loadVaultTerms()
        model.selfWikilinkText = "jordan"
        #expect(model.selfWikilinkSuggestions == (1 ... 5).map { "Jordan \($0)" })
    }

    @Test("No query means no suggestions", arguments: ["", "  ", "[[]]", "[[ ]]", "[[|alias]]"])
    func noQueryNoSuggestions(text: String) async throws {
        let model = try makeModel(vaultDirectory: vault, vaultTerms: { _ in Glossary(people: ["Jordan Lee"]) })
        await model.loadVaultTerms()
        model.selfWikilinkText = text
        #expect(model.selfWikilinkSuggestions.isEmpty)
    }

    @Test func theNameAlreadyInTheFieldIsLeftOutAndTheAliasIsIgnored() async throws {
        let model = try makeModel(vaultDirectory: vault, vaultTerms: { _ in
            Glossary(people: ["Jordan Lee", "Jordan Leeds"])
        })
        await model.loadVaultTerms()
        model.selfWikilinkText = "[[Jordan Lee]]"
        #expect(model.selfWikilinkSuggestions == ["Jordan Leeds"])
        model.selfWikilinkText = "[[Jordan Lee|me]]"
        #expect(model.selfWikilinkSuggestions == ["Jordan Lee", "Jordan Leeds"])
    }

    @Test func selectingASuggestionWrapsItAsTheFieldText() throws {
        let model = try makeModel(vaultDirectory: vault)
        model.selectSuggestion("Jordan Lee")
        #expect(model.selfWikilinkText == "[[Jordan Lee]]")
    }
}

@MainActor
struct SelfWikilinkRoundTripTests {
    @Test func finishWritesSelfWikilinkThatConfigReadsBack() throws {
        let home = try makeTemporaryDirectory()
        let vaultDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: vaultDirectory)
        }

        let model = try makeModel(
            vaultDirectory: vaultDirectory,
            writeVaultPath: { try ConfigWriter.set("vault_path", to: $0.path, homeDirectory: home) },
            writeSelfWikilink: { try ConfigWriter.set("self.wikilink", to: $0, homeDirectory: home) },
        )
        model.selfWikilinkText = "  [[Jordan]]  "
        try model.confirmSelfWikilink()
        try model.finish()

        let config = try Config.load(homeDirectory: home)
        #expect(config.selfWikilink == "[[Jordan]]")
        #expect(config.vaultPath?.standardizedFileURL.path == vaultDirectory.standardizedFileURL.path)
    }
}
